package io.dexlink.dex_phone

import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import java.io.OutputStream
import java.io.DataOutputStream
import io.dexlink.dex_phone.capture.VideoSender
import io.dexlink.dex_phone.capture.SenderBitrateControl
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Screen mirroring without any privileged helper.
 *
 * `MediaProjection` lets an ordinary app capture the whole screen, and
 * `MediaCodec` turns that surface into H.264. The output is framed exactly like
 * DexLink's video channel so the PC client does not need a second code path.
 */
class MirrorEncoder(
    private val context: Context,
    private val resultCode: Int,
    private val projectionData: Intent,
    private var maxDimension: Int,
    private var bitrate: Int,
    private val onError: (String) -> Unit,
) {
    companion object {
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val CODEC_ID_H264 = 0x68323634
        private const val DEVICE_NAME_LENGTH = 64
        private const val FRAME_RATE = 60
        private const val FRAME_FLAG_CONFIG = 1L shl 62
        private const val FRAME_FLAG_KEY = 1L shl 61
    }

    @Volatile
    private var running = false
    private var frameRate = FRAME_RATE
    private var preferHevc = false
    private var codecId = CODEC_ID_H264

    @Synchronized
    fun configure(options: CaptureOptions) {
        check(!running && encoderThread == null) { "镜像已启动，无法修改采集参数" }
        maxDimension = options.maxSize
        bitrate = options.bitrate
        frameRate = options.fps
        preferHevc = options.features and CaptureOptions.PREFER_HEVC != 0
    }

    @Volatile
    private var codec: MediaCodec? = null
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoderThread: Thread? = null

    /** Size of the captured (scaled) display; the PC maps pointer coordinates to it. */
    @Volatile
    var width = 0
        private set

    @Volatile
    var height = 0
        private set

    @Volatile
    var densityDpi = 0
        private set

    /** Real screen size, needed to map pointers back for input injection. */
    @Volatile
    var screenWidth = 0
        private set

    @Volatile
    var screenHeight = 0
        private set

    /** Requests an immediate IDR sync frame from the hardware encoder. */
    fun requestSyncFrame() {
        val active = codec ?: return
        try {
            active.setParameters(
                Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                },
            )
        } catch (_: Throwable) {
        }
    }

    /**
     * Starts capturing and writes the video channel into [sink]. Called once the
     * PC has opened the video connection, so nothing is encoded while idle.
     */
    fun attach(sink: OutputStream) {
        if (running || encoderThread != null) {
            BridgeEvents.log("w", "上一次镜像还在收尾，先结束它")
            stop()
        }
        running = true
        encoderThread = Thread({ run(sink) }, "dexlink-mirror").also { it.start() }
    }

    private fun run(sink: OutputStream) {
        try {
            val (sw, sh) = realScreenSize(context)
            screenWidth = sw
            screenHeight = sh
            densityDpi = context.resources.displayMetrics.densityDpi

            val scale = minOf(1.0, maxDimension.toDouble() / maxOf(sw, sh))
            width = ((sw * scale).toInt() / 2) * 2
            height = ((sh * scale).toInt() / 2) * 2

            val mediaProjection = projection ?: run {
                val manager = context.getSystemService(MediaProjectionManager::class.java)
                (manager.getMediaProjection(resultCode, projectionData)
                    ?: throw IllegalStateException("无法获取录屏授权，请重新授权"))
                    .also { fresh ->
                        fresh.registerCallback(
                            object : MediaProjection.Callback() {
                                override fun onStop() {
                                    if (running) {
                                        BridgeEvents.log("w", "录屏授权已被系统回收")
                                        stop(releaseProjection = false)
                                        onError("录屏授权被系统回收，请重新开始镜像")
                                    }
                                }
                            },
                            Handler(Looper.getMainLooper()),
                        )
                        projection = fresh
                    }
            }

            val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
                setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                )
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setFloat("max-fps-to-encoder", frameRate.toFloat())
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                // Use real-time encoder settings: emit a frame as
                // soon as one is queued rather than batch frames for throughput.
                setInteger(MediaFormat.KEY_PRIORITY, 0)
                setInteger(MediaFormat.KEY_LATENCY, 1)
                setInteger(
                    MediaFormat.KEY_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline,
                )
                // Real-time encoder priority and operating rate eliminate
                // multi-frame hardware batching delay on Qualcomm/MediaTek SoCs.
                setInteger(MediaFormat.KEY_OPERATING_RATE, frameRate)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                }
                // Keep idle streams alive without encoding duplicate pictures
                // at the requested maximum frame rate.
                setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
            }
            val input = io.dexlink.dex_phone.capture.EncoderSelection.createInput(format, preferHevc)
            val mediaCodec = input.codec
            codecId = if (format.getString(MediaFormat.KEY_MIME) == "video/hevc") 0x68323635 else CODEC_ID_H264
            val surface = input.surface
            mediaCodec.start()
            codec = mediaCodec

            try {
                virtualDisplay?.release()
            } catch (_: Throwable) {
            }
            virtualDisplay = null

            val display = mediaProjection.createVirtualDisplay(
                "DexLink",
                width,
                height,
                densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR or
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC,
                surface,
                null,
                null,
            )
            if (display == null) {
                throw IllegalStateException("系统拒绝创建录屏虚拟屏，请重新授权录屏")
            }
            virtualDisplay = display
            BridgeEvents.log("i", "镜像虚拟屏已创建 ${width}x$height @ ${densityDpi}dpi")

            writePrologue(sink)
            drain(mediaCodec, sink)
        } catch (t: Throwable) {
            if (running) {
                BridgeEvents.log("e", "镜像线程异常: ${t.message ?: t.javaClass.simpleName}")
                onError(t.message ?: t.javaClass.simpleName)
            }
        } finally {
            stop()
            BridgeEvents.log("i", "镜像线程结束")
        }
    }

    private fun writePrologue(sink: OutputStream) {
        val name = ByteArray(DEVICE_NAME_LENGTH)
        val model = (Build.MODEL ?: "Android").toByteArray(Charsets.UTF_8)
        System.arraycopy(model, 0, name, 0, minOf(model.size, DEVICE_NAME_LENGTH - 1))
        sink.write(name)
        sink.write(int32(codecId))
        sink.write(int32(Int.MIN_VALUE or (frameRate shl 8)))
        sink.write(int32(width))
        sink.write(int32(height))
        sink.flush()
    }

    private fun drain(mediaCodec: MediaCodec, sink: OutputStream) {
        val info = MediaCodec.BufferInfo()
        var sent = 0
        var lastLog = 0L
        val sender = VideoSender(DataOutputStream(sink), { requestSyncFrame() }, { _, _, _, _ -> })
        sender.setBitrate(bitrate)
        val localRate = SenderBitrateControl(bitrate, true)
        var activeBitrate = bitrate
        var localRateSupported = true
        requestSyncFrame()

        try {
            while (running) {
                sender.checkFailure()
                val next = if (localRateSupported)
                    localRate.sample(android.os.SystemClock.elapsedRealtime(), activeBitrate, sender)
                    else activeBitrate
                if (next != activeBitrate) {
                    try {
                        mediaCodec.setParameters(android.os.Bundle().apply {
                            putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, next)
                        })
                        activeBitrate = next
                        sender.setBitrate(next)
                    } catch (unsupported: RuntimeException) {
                        localRateSupported = false
                        BridgeEvents.log("w", "编码器拒绝动态码率：${unsupported.message}")
                    }
                }
                val index = mediaCodec.dequeueOutputBuffer(info, 8_000)
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) continue
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val out = mediaCodec.outputFormat
                    BridgeEvents.log(
                        "i",
                        "编码器输出就绪：${out.getString(MediaFormat.KEY_MIME)} " +
                            "${out.getInteger(MediaFormat.KEY_WIDTH)}x${out.getInteger(MediaFormat.KEY_HEIGHT)}",
                    )
                    continue
                }
                if (index < 0) continue
                var released = false
                try {
                    if (info.size > 0) {
                        val buffer: ByteBuffer = mediaCodec.getOutputBuffer(index) ?: continue
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val payload = ByteArray(info.size)
                        buffer.get(payload)
                        val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        if (!config) localRate.frame(android.os.SystemClock.elapsedRealtime())
                        val key = (!config && sent == 0) ||
                            (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        // Do not hold a codec output slot while the socket blocks.
                        mediaCodec.releaseOutputBuffer(index, false)
                        released = true
                        try {
                            val flags = if (config) FRAME_FLAG_CONFIG
                                else info.presentationTimeUs or (if (key) FRAME_FLAG_KEY else 0L)
                            sender.offer(flags, payload)
                        } catch (io: Throwable) {
                            BridgeEvents.log(
                                "w",
                                "写视频通道失败（已提交 $sent 帧）: ${io.message ?: io.javaClass.simpleName}",
                            )
                            return
                        }
                        if (!config) {
                            sent++
                            val now = System.currentTimeMillis()
                            if (now - lastLog >= 3000) {
                                lastLog = now
                                BridgeEvents.log("i", "已提交发送队列 $sent 帧（${payload.size} 字节/帧）")
                            }
                        }
                    }
                } finally {
                    try {
                        if (!released) mediaCodec.releaseOutputBuffer(index, false)
                    } catch (_: Throwable) {
                    }
                }
            }
        } finally {
            sender.close()
            // Cancels a blocked writer before waiting; never leave a network
            // thread holding an old projection after disconnect/reconfigure.
            try { sink.close() } catch (_: Throwable) { }
            sender.awaitTermination()
        }
        BridgeEvents.log("i", "镜像编码结束，共 $sent 帧")
    }

    fun stop(releaseProjection: Boolean = false) {
        if (!running && codec == null && encoderThread == null) return
        running = false
        try {
            codec?.stop()
        } catch (_: Throwable) {
        }
        try {
            codec?.release()
        } catch (_: Throwable) {
        }
        codec = null
        try {
            virtualDisplay?.release()
        } catch (_: Throwable) {
        }
        virtualDisplay = null
        if (releaseProjection) {
            try {
                projection?.stop()
            } catch (_: Throwable) {
            }
            projection = null
        }
        val thread = encoderThread
        encoderThread = null
        if (thread != null && thread !== Thread.currentThread()) {
            thread.interrupt()
        }
    }

    private fun realScreenSize(context: Context): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = context.getSystemService(WindowManager::class.java)
                .maximumWindowMetrics
                .bounds
            return bounds.width() to bounds.height()
        }
        @Suppress("DEPRECATION")
        val metrics = context.resources.displayMetrics
        return metrics.widthPixels to metrics.heightPixels
    }

    private fun int32(value: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(value).array()
}
