package io.dexlink.dex_phone

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.PointF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import kotlin.math.hypot

/**
 * Decodes the control channel and applies it through [DexAccessibilityService].
 *
 * Both capture modes share the DexLink wire format (see docs/PROTOCOL.md), so the PC
 * client is identical for both modes; only the executor differs.
 */
class ControlTranslator(
    private val context: Context,
    private val encoder: MirrorEncoder,
    private val onClosed: (String) -> Unit,
) {
    companion object {
        private const val TYPE_KEYCODE = 0
        private const val TYPE_TEXT = 1
        private const val TYPE_TOUCH = 2
        private const val TYPE_SCROLL = 3
        private const val TYPE_BACK_OR_SCREEN_ON = 4
        private const val TYPE_EXPAND_NOTIFICATIONS = 5
        private const val TYPE_EXPAND_SETTINGS = 6
        private const val TYPE_COLLAPSE_PANELS = 7
        private const val TYPE_GET_CLIPBOARD = 8
        private const val TYPE_SET_CLIPBOARD = 9
        private const val TYPE_SET_DISPLAY_POWER = 10
        private const val TYPE_ROTATE = 11
        private const val TYPE_START_APP = 16
        private const val TYPE_RESET_VIDEO = 17

        private const val ACTION_DOWN = 0
        private const val ACTION_UP = 1
        private const val ACTION_MOVE = 2
        private const val ACTION_CANCEL = 3

        private const val KEY_HOME = 3
        private const val KEY_BACK = 4
        private const val KEY_VOLUME_UP = 24
        private const val KEY_VOLUME_DOWN = 25
        private const val KEY_TAB = 61
        private const val KEY_ENTER = 66
        private const val KEY_DEL = 67
        private const val KEY_MENU = 82
        private const val KEY_ESCAPE = 111
        private const val KEY_FORWARD_DEL = 112
        private const val KEY_APP_SWITCH = 187

        /** Pixels of finger travel per scroll notch. */
        private const val SCROLL_PIXELS_PER_UNIT = 240f
    }

    @Volatile
    private var running = true

    private var thread: Thread? = null
    private val points = mutableListOf<PointF>()
    private var downAt = 0L
    private var statusBarTriggered = false
    private var warnedMissingAccessibility = false

    private fun serviceOrWarn(): DexAccessibilityService? {
        val current = DexAccessibilityService.instance
        if (current != null) {
            warnedMissingAccessibility = false
            return current
        }
        if (!warnedMissingAccessibility) {
            warnedMissingAccessibility = true
            BridgeEvents.log("w", "收到电脑点击/按键，但手机尚未开启 DexLink 无障碍服务")
        }
        return null
    }

    fun attach(input: InputStream) {
        if (thread != null) return
        thread = Thread({ parse(input) }, "dexlink-control").also { it.start() }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
    }

    private fun parse(input: InputStream) {
        val stream = DataInputStream(BufferedInputStream(input, 16 * 1024))
        var reason = "电脑端已断开"
        try {
            while (running) {
                when (val type = stream.readUnsignedByte()) {
                    TYPE_KEYCODE -> {
                        val action = stream.readUnsignedByte()
                        val keycode = stream.readInt()
                        stream.readInt() // repeat
                        stream.readInt() // metaState
                        onKey(action, keycode)
                    }

                    TYPE_TEXT -> {
                        val text = readString(stream)
                        serviceOrWarn()?.typeText(text)
                        encoder.requestSyncFrame()
                    }

                    TYPE_TOUCH -> {
                        val action = stream.readUnsignedByte()
                        stream.readLong() // pointerId
                        val x = stream.readInt()
                        val y = stream.readInt()
                        stream.readUnsignedShort() // screen width
                        stream.readUnsignedShort() // screen height
                        stream.readShort() // pressure
                        stream.readInt() // action button
                        stream.readInt() // buttons
                        onTouch(action, x, y)
                    }

                    TYPE_SCROLL -> {
                        val x = stream.readInt()
                        val y = stream.readInt()
                        stream.readUnsignedShort()
                        stream.readUnsignedShort()
                        val hScroll = stream.readShort() / 32768f * 16f
                        val vScroll = stream.readShort() / 32768f * 16f
                        stream.readInt() // buttons
                        onScroll(x, y, hScroll, vScroll)
                    }

                    TYPE_BACK_OR_SCREEN_ON -> {
                        val action = stream.readUnsignedByte()
                        if (action == ACTION_DOWN) {
                            serviceOrWarn()?.globalBack()
                            encoder.requestSyncFrame()
                        }
                    }

                    TYPE_EXPAND_NOTIFICATIONS -> {
                        serviceOrWarn()?.globalNotifications()
                        encoder.requestSyncFrame()
                    }

                    TYPE_EXPAND_SETTINGS -> {
                        val svc = serviceOrWarn()
                        if (svc != null && !svc.globalQuickSettings()) {
                            svc.globalNotifications()
                        }
                        encoder.requestSyncFrame()
                    }

                    TYPE_COLLAPSE_PANELS -> {
                        serviceOrWarn()?.globalBack()
                        encoder.requestSyncFrame()
                    }

                    TYPE_GET_CLIPBOARD -> stream.readUnsignedByte()

                    TYPE_SET_CLIPBOARD -> {
                        stream.readLong() // sequence
                        val paste = stream.readUnsignedByte() != 0
                        onSetClipboard(readString(stream), paste)
                    }

                    TYPE_SET_DISPLAY_POWER -> stream.readUnsignedByte()

                    TYPE_ROTATE -> encoder.requestSyncFrame()
                    TYPE_RESET_VIDEO -> encoder.requestSyncFrame()

                    TYPE_START_APP -> onStartApp(readTinyString(stream))

                    else -> {
                        reason = "未知控制指令: $type"
                        return
                    }
                }
            }
        } catch (_: EOFException) {
            // Peer closed.
        } catch (_: Throwable) {
            // Socket torn down or gesture service gone.
        } finally {
            running = false
            onClosed(reason)
        }
    }

    // ------------------------------------------------------------- touch input

    private fun onTouch(action: Int, x: Int, y: Int) {
        val point = PointF(x * scaleX(), y * scaleY())
        when (action) {
            ACTION_DOWN -> {
                points.clear()
                points.add(point)
                downAt = SystemClock.uptimeMillis()
                statusBarTriggered = false
            }

            ACTION_MOVE -> {
                if (points.isEmpty()) return
                val start = points.first()
                val last = points.last()
                if (hypot(last.x - point.x, last.y - point.y) > 4f) {
                    points.add(point)
                }
                // Pulling down from the top status bar area (top 6.5% of screen):
                // Android's StatusBar window rejects synthetic dispatchGesture
                // touches starting inside the status bar, so fire the system
                // global action immediately while the user is dragging down!
                val sh = encoder.screenHeight.coerceAtLeast(1000)
                val sw = encoder.screenWidth.coerceAtLeast(500)
                if (!statusBarTriggered &&
                    start.y <= sh * 0.065f &&
                    point.y - start.y > sh * 0.055f &&
                    kotlin.math.abs(point.x - start.x) < sw * 0.35f
                ) {
                    statusBarTriggered = true
                    val service = serviceOrWarn()
                    if (service != null) {
                        if (start.x > sw * 0.52f) {
                            if (!service.globalQuickSettings()) {
                                service.globalNotifications()
                            }
                        } else {
                            service.globalNotifications()
                        }
                        encoder.requestSyncFrame()
                    }
                }
            }

            ACTION_UP -> {
                val start = points.firstOrNull()
                if (start != null && !statusBarTriggered) {
                    val service = serviceOrWarn()
                    if (service != null) {
                        val elapsed = SystemClock.uptimeMillis() - downAt
                        val moved = points.any { hypot(it.x - start.x, it.y - start.y) > 12f }
                        if (!moved) {
                            if (elapsed >= 480L) {
                                service.longPress(start.x, start.y)
                            } else {
                                service.tap(start.x, start.y)
                            }
                        } else {
                            // Execute swipe with a fast, snappy duration so there
                            // is no multi-hundred-millisecond replay lag after mouse up.
                            val duration = (elapsed / 3).coerceIn(50L, 130L)
                            service.drag(points.toList(), duration)
                        }
                        encoder.requestSyncFrame()
                    }
                }
                points.clear()
                statusBarTriggered = false
            }

            ACTION_CANCEL -> {
                points.clear()
                statusBarTriggered = false
            }
        }
    }

    private fun onScroll(x: Int, y: Int, hScroll: Float, vScroll: Float) {
        val service = serviceOrWarn() ?: return
        val distance = -vScroll * SCROLL_PIXELS_PER_UNIT
        service.scroll(x * scaleX(), y * scaleY(), distance)
        encoder.requestSyncFrame()
    }

    // ------------------------------------------------------------ key and text

    private fun onKey(action: Int, keycode: Int) {
        if (action != ACTION_DOWN) return
        val service = serviceOrWarn() ?: return
        when (keycode) {
            KEY_HOME -> service.globalHome()
            KEY_BACK, KEY_ESCAPE -> service.globalBack()
            KEY_APP_SWITCH -> service.globalRecents()
            KEY_ENTER -> service.typeText("\n")
            KEY_TAB -> service.typeText("\t")
            KEY_DEL, KEY_FORWARD_DEL -> service.deleteBeforeCursor()
            KEY_MENU -> service.globalNotifications()
            KEY_VOLUME_UP -> adjustVolume(true)
            KEY_VOLUME_DOWN -> adjustVolume(false)
            else -> Unit
        }
        encoder.requestSyncFrame()
    }

    private fun adjustVolume(up: Boolean) {
        try {
            val audio = context.getSystemService(android.media.AudioManager::class.java)
            audio?.adjustSuggestedStreamVolume(
                if (up) android.media.AudioManager.ADJUST_RAISE
                else android.media.AudioManager.ADJUST_LOWER,
                android.media.AudioManager.USE_DEFAULT_STREAM_TYPE,
                android.media.AudioManager.FLAG_SHOW_UI,
            )
        } catch (_: Throwable) {
        }
    }

    private fun onSetClipboard(text: String, paste: Boolean = false) {
        try {
            val manager = context.getSystemService(ClipboardManager::class.java)
            manager.setPrimaryClip(ClipData.newPlainText("DexLink", text))
        } catch (t: Throwable) {
            BridgeEvents.log("w", "写入手机剪贴板失败：${t.message}")
            return
        }
        if (!paste) return
        Handler(Looper.getMainLooper()).post {
            val pasted = DexAccessibilityService.instance?.pasteIntoFocused() == true
            if (!pasted) BridgeEvents.log("w", "剪贴板已更新，但没有可粘贴的输入框")
            encoder.requestSyncFrame()
        }
    }

    private fun onStartApp(name: String) {
        try {
            val intent = context.packageManager.getLaunchIntentForPackage(name.substringBefore('/'))
                ?: return
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (_: Throwable) {
        }
    }

    // ------------------------------------------------------------------ helpers

    private fun scaleX(): Float =
        if (encoder.width > 0) encoder.screenWidth.toFloat() / encoder.width else 1f

    private fun scaleY(): Float =
        if (encoder.height > 0) encoder.screenHeight.toFloat() / encoder.height else 1f

    private fun readString(stream: DataInputStream): String {
        val length = stream.readInt()
        if (length < 0 || length > 1 shl 20) throw IllegalStateException("bad string length")
        val bytes = ByteArray(length)
        stream.readFully(bytes)
        return String(bytes, Charsets.UTF_8)
    }

    private fun readTinyString(stream: DataInputStream): String {
        val length = stream.readUnsignedByte()
        val bytes = ByteArray(length)
        stream.readFully(bytes)
        return String(bytes, Charsets.UTF_8)
    }
}
