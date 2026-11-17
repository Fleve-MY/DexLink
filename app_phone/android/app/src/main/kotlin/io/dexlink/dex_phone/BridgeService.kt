package io.dexlink.dex_phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.content.pm.ServiceInfo
import org.json.JSONArray
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Hosts DexLink capture, input and file channels. Privileged capture is loaded
 * from this app's own APK; ordinary capture uses MediaProjection in-process.
 */
class BridgeService : Service() {

    companion object {
        const val ACTION_START = "io.dexlink.dex_phone.START"
        const val ACTION_STOP = "io.dexlink.dex_phone.STOP"

        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_DPI = "dpi"
        const val EXTRA_BITRATE = "bitrate"
        const val EXTRA_NEW_DISPLAY = "newDisplay"
        const val EXTRA_PORT = "port"
        const val EXTRA_MODE = "mode"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_PROJECTION_DATA = "projectionData"

        /** Independent 1920x1080 desktop display, requires Shizuku. */
        const val MODE_DESKTOP = 0

        /** 1:1 screen mirroring through MediaProjection, no setup required. */
        const val MODE_MIRROR = 1

        private const val CHANNEL_ID = "dexlink_session"
        private const val NOTIFICATION_ID = 27190

        /** Must match `kDiscoveryPort` in packages/dex_link. */
        private const val DISCOVERY_PORT = 27191
        private const val DISCOVERY_REQUEST = "DEXLINK/1 DISCOVER"

        private const val CHANNEL_VIDEO = 'V'.code
        private const val CHANNEL_CONTROL = 'C'.code
        private const val CHANNEL_FILES = 'F'.code

        /**
         * Identification probe. The PC scans its subnet by opening this channel
         * and reading a one-line answer, which works even when Windows Firewall
         * swallows the UDP discovery replies.
         */
        private const val CHANNEL_PROBE = 'P'.code

        private const val FILE_LIST = 1
        private const val FILE_PULL = 2
        private const val FILE_PUSH = 3
        private const val FILE_MKDIR = 4

        /** Publishes an uploaded file and puts it on the phone's clipboard. */
        private const val FILE_PASTE = 5
        private const val FILE_PASTE_RICH = 6
        private const val FILE_PASTE_TARGET = 7
        private const val FILE_SHARE_ATTACHMENTS = 8

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var port = 27190
            private set

        @Volatile
        var displaySize = ""
            private set

        @Volatile
        var lastError: String? = null
            private set

        /** Which mode the current (or last) session used. */
        @Volatile
        var runningMode: Int = MODE_DESKTOP
            private set

        @Volatile
        var mirrorEngine: String = "none"
            private set

        /** `Environment.isExternalStorageManager()` only exists on Android 11+. */
        fun hasAllFilesAccess(): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                Environment.isExternalStorageManager()
    }

    private val stopping = AtomicBoolean(false)
    private var serverProcess: Process? = null
    private var videoSocket: Socket? = null
    private var controlSocket: Socket? = null
    private var captureListener: ServerSocket? = null
    private val videoAttached = AtomicBoolean(false)
    private val controlAttached = AtomicBoolean(false)
    private val captureSettingsLock = Any()
    private var captureOptions: CaptureOptions? = null
    private var directPort = 0
    private var directToken: String? = null
    private var tcpServer: ServerSocket? = null
    private var discoverySocket: DatagramSocket? = null
    private var sessionThread: Thread? = null

    private var mode = MODE_DESKTOP
    private var shizukuMirror = false
    private var mirrorEncoder: MirrorEncoder? = null
    private var controlTranslator: ControlTranslator? = null
    private var projectionResultCode = 0
    private var projectionData: Intent? = null
    private var foregroundIsProjection = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action == ACTION_STOP) {
            stopSession(null)
            return START_NOT_STICKY
        }

        startInForeground("正在准备会话…")

        if (isRunning || sessionThread?.isAlive == true) {
            return START_NOT_STICKY
        }

        mode = intent.getIntExtra(EXTRA_MODE, MODE_DESKTOP)
        runningMode = mode
        projectionResultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        @Suppress("DEPRECATION")
        projectionData = intent.getParcelableExtra(EXTRA_PROJECTION_DATA)
        shizukuMirror = mode == MODE_MIRROR &&
            projectionData == null &&
            ShizukuSupport.isAvailable() &&
            ShizukuSupport.hasPermission()
        foregroundIsProjection = mode == MODE_MIRROR && !shizukuMirror
        mirrorEngine = if (mode != MODE_MIRROR) "none" else if (shizukuMirror) "shizuku" else "projection"
        if (foregroundIsProjection) {
            // Android 14+ requires the mediaProjection foreground type to be
            // active before getMediaProjection() is called.
            try {
                startInForeground("正在准备镜像…", true)
            } catch (_: Throwable) {
                // Older platforms ignore the type.
            }
        }

        val width = intent.getIntExtra(EXTRA_WIDTH, 1920).coerceIn(640, 3840)
        val height = intent.getIntExtra(EXTRA_HEIGHT, 1080).coerceIn(480, 2160)
        val dpi = intent.getIntExtra(EXTRA_DPI, 160).coerceIn(96, 480)
        val bitrate = intent.getIntExtra(EXTRA_BITRATE, 12_000_000)
        val newDisplay = if (shizukuMirror) {
            false
        } else {
            intent.getBooleanExtra(EXTRA_NEW_DISPLAY, true)
        }
        port = intent.getIntExtra(EXTRA_PORT, 27190)
        lastError = null

        sessionThread = thread(name = "dexlink-session") {
            if (mode == MODE_MIRROR && !shizukuMirror) {
                runMirror(bitrate)
            } else {
                runSession(width, height, dpi, bitrate, newDisplay)
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopSession(null, fromDestroy = true)
        super.onDestroy()
    }

    // ---------------------------------------------------------------- session

    private fun runSession(
        width: Int,
        height: Int,
        dpi: Int,
        bitrate: Int,
        newDisplay: Boolean,
    ) {
        try {
            if (!ShizukuSupport.isAvailable()) {
                fail("Shizuku 没有运行，请先启动 Shizuku 并授权本应用")
                return
            }
            if (!ShizukuSupport.hasPermission()) {
                fail("尚未获得 Shizuku 授权")
                return
            }

            BridgeEvents.log("i", "启动 DexLink 采集（${bitrate / 1_000_000}Mbps）")
            startCapture(width, height, dpi, bitrate, newDisplay)

            val server = bindTcp()
            if (server == null) {
                fail("TCP 端口 $port 被占用")
                return
            }
            tcpServer = server
            displaySize = if (newDisplay) "${width}x$height" else "手机屏幕 · 长边上限 2560"
            isRunning = true
            startDiscovery()
            BridgeEvents.log("i", "已就绪，等待电脑连接（端口 $port）")
            BridgeEvents.status()
            startInForeground("等待电脑连接 · 端口 $port")

            while (!stopping.get()) {
                val socket = try {
                    server.accept()
                } catch (t: Throwable) {
                    if (stopping.get() || !isRunning) return
                    fail("监听中断：${t.message}")
                    return
                }
                thread(name = "dexlink-pump") { dispatch(socket) }
            }
        } catch (t: Throwable) {
            fail(t.message ?: t.javaClass.simpleName)
        }
    }

    /**
     * Ordinary mirror mode needs no Shizuku. Video comes from
     * [MirrorEncoder] and the control channel is executed by
     * [DexAccessibilityService].
     */
    private fun runMirror(bitrate: Int) {
        try {
            val data = projectionData
            if (data == null || projectionResultCode == 0) {
                fail("没有拿到录屏授权，请重新点一次「开始镜像」")
                return
            }
            val server = bindTcp()
            if (server == null) {
                fail("TCP 端口 $port 被占用")
                return
            }
            tcpServer = server
            mirrorEncoder = MirrorEncoder(
                context = this,
                resultCode = projectionResultCode,
                projectionData = data,
                // Match the PC output cap instead of encoding pixels that the
                // decoder immediately scales away.
                maxDimension = 2560,
                bitrate = bitrate,
                onError = { message -> fail(message) },
            )
            isRunning = true
            startDiscovery()
            BridgeEvents.log("i", "镜像模式就绪，等待电脑连接（端口 $port）")
            BridgeEvents.status()
            startInForeground("等待电脑连接 · 端口 $port", foregroundIsProjection)

            while (!stopping.get()) {
                val socket = try {
                    server.accept()
                } catch (t: Throwable) {
                    if (stopping.get() || !isRunning) return
                    fail("监听中断：${t.message}")
                    return
                }
                thread(name = "dexlink-pump") { dispatch(socket) }
            }
        } catch (t: Throwable) {
            fail(t.message ?: t.javaClass.simpleName)
        }
    }

    private fun dispatch(socket: Socket) {
        try {
            socket.tcpNoDelay = true
            val input = BufferedInputStream(socket.getInputStream(), 256 * 1024)
            when (val channel = input.read()) {
                CHANNEL_VIDEO -> if (mode == MODE_MIRROR && !shizukuMirror) {
                    attachMirrorVideo(socket)
                } else {
                    val attached = synchronized(captureSettingsLock) {
                        if (!videoAttached.compareAndSet(false, true)) false else {
                            val settings = captureOptions
                            val output = DataOutputStream(videoSocket!!.getOutputStream())
                            if (settings == null) output.writeByte(1) else {
                                output.writeByte(2)
                                settings.write(output)
                            }
                            output.flush()
                            true
                        }
                    }
                    if (!attached) {
                        closeQuietly(socket)
                    } else {
                        pump(videoSocket, socket, input)
                    }
                }

                CHANNEL_CONTROL -> if (mode == MODE_MIRROR && !shizukuMirror) {
                    attachMirrorControl(socket, input)
                } else {
                    val attached = synchronized(captureSettingsLock) {
                        controlAttached.compareAndSet(false, true)
                    }
                    if (!attached) {
                        closeQuietly(socket)
                    } else {
                        pump(controlSocket, socket, input)
                    }
                }

                CHANNEL_FILES -> serveFiles(socket, input)

                CHANNEL_PROBE -> replyProbe(socket)
                'Q'.code -> configureCapture(socket, input)

                else -> {
                    BridgeEvents.log("w", "未知通道: $channel")
                    socket.close()
                }
            }
        } catch (t: Throwable) {
            BridgeEvents.log("w", "连接异常：${t.message}")
            closeQuietly(socket)
        }
    }

    private fun configureCapture(socket: Socket, input: InputStream) {
        socket.soTimeout = 5000
        val result = JSONObject()
        try {
            val options = CaptureOptions.read(DataInputStream(input))
            synchronized(captureSettingsLock) {
                check(!videoAttached.get() && !controlAttached.get()) { "已有电脑连接，请先停止手机投屏再重新开始" }
                mirrorEncoder?.configure(options)
                captureOptions = options
                if (directPort != 0) {
                    val output = DataOutputStream(videoSocket!!.getOutputStream())
                    output.writeByte(2)
                    options.write(output)
                    output.flush()
                    videoAttached.set(true)
                    controlAttached.set(true)
                    result.put("streamPort", directPort).put("streamToken", directToken)
                        .put("audio", true)
                }
            }
            result.put("ok", true)
            BridgeEvents.log("i", "电脑设置：${options.fps} FPS / 长边 ${options.maxSize} / ${options.bitrate / 1_000_000} Mbps")
        } catch (error: Exception) {
            result.put("ok", false).put("error", error.message ?: "无法应用设置")
        }
        try {
            socket.getOutputStream().write((result.toString() + "\n").toByteArray(Charsets.UTF_8))
        } finally { closeQuietly(socket) }
    }

    /** Answers a PC subnet probe with the same payload UDP discovery uses. */
    private fun replyProbe(socket: Socket) {
        try {
            val name = (Build.MODEL ?: "Android").replace("\"", "")
            val reply = """DEXLINK/1 {"proto":1,"name":"$name","port":$port}"""
            val out = socket.getOutputStream()
            out.write(reply.toByteArray(Charsets.UTF_8))
            out.flush()
        } catch (_: Throwable) {
            // The scanner only needs a best-effort answer.
        } finally {
            closeQuietly(socket)
        }
    }

    /** Hands the PC's video socket to the encoder and waits for it to hang up. */
    private fun attachMirrorVideo(socket: Socket) {
        val encoder = mirrorEncoder
        if (encoder == null) {
            BridgeEvents.log("e", "镜像还没有初始化")
            closeQuietly(socket)
            return
        }
        try {
            socket.tcpNoDelay = true
            synchronized(captureSettingsLock) {
                check(videoAttached.compareAndSet(false, true)) { "已有画面连接" }
                socket.sendBufferSize = 64 * 1024
                encoder.attach(BufferedOutputStream(socket.getOutputStream(), 256 * 1024))
            }
            val scratch = ByteArray(256)
            while (socket.getInputStream().read(scratch) >= 0) {
                // The video channel is one-way; ignore anything the PC sends.
            }
        } catch (_: Throwable) {
            // Either side closing ends the session below.
        } finally {
            closeQuietly(socket)
            if (isRunning) stopSession("电脑端已断开")
        }
    }

    private fun attachMirrorControl(socket: Socket, input: InputStream) {
        synchronized(captureSettingsLock) {
            if (!controlAttached.compareAndSet(false, true)) {
                closeQuietly(socket)
                return
            }
        }
        val encoder = mirrorEncoder
        if (encoder == null) {
            BridgeEvents.log("e", "镜像还没有初始化")
            closeQuietly(socket)
            return
        }
        if (DexAccessibilityService.instance == null) {
            BridgeEvents.log("w", "无障碍服务尚未开启：目前仅可观看画面与发送剪贴板，开启无障碍后即可键鼠操作")
        }
        val translator = ControlTranslator(this, encoder) {
            closeQuietly(socket)
        }
        controlTranslator = translator
        BridgeEvents.log("i", "控制通道已连接")
        translator.attach(input)
    }

    /** Shuttles bytes between the private capture connection and the PC. */
    private fun pump(local: Socket?, socket: Socket, alreadyBuffered: InputStream) {
        if (local == null) {
            BridgeEvents.log("e", "会话已结束，拒绝连接")
            closeQuietly(socket)
            return
        }
        socket.tcpNoDelay = true
        val upstream = thread(name = "dexlink-up") {
            copyStream(local.getInputStream(), socket.getOutputStream())
        }
        val downstream = thread(name = "dexlink-down") {
            copyStream(alreadyBuffered, local.getOutputStream())
        }
        upstream.join()
        // Closing the PC socket unblocks the downstream reader.
        closeQuietly(socket)
        downstream.join()
        BridgeEvents.log("i", "电脑端已断开")
        stopSession("电脑端已断开")
    }

    private fun copyStream(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(256 * 1024)
        try {
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                output.write(buffer, 0, read)
                output.flush()
            }
        } catch (_: Throwable) {
            // Either side closing is a normal end of session.
        }
    }

    // ------------------------------------------------------------- file share

    /**
     * Tiny request/response protocol, one op per message:
     *   LIST:  [1][path]        -> [json]
     *   PULL:  [2][path]        -> [8 size][bytes]
     *   PUSH:  [3][path][8 size][bytes] -> [1 ok]
     *   MKDIR: [4][path]        -> [1 ok]
     */
    private fun serveFiles(socket: Socket, buffered: InputStream) {
        val input = DataInputStream(buffered)
        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), 256 * 1024))
        val root = shareRoot()
        try {
            while (true) {
                when (val op = input.readUnsignedByte()) {
                    FILE_LIST -> {
                        val path = readString(input)
                        writeString(output, listJson(resolve(root, path)))
                    }

                    FILE_PULL -> {
                        val file = resolve(root, readString(input))
                        if (file.isFile) {
                            output.writeLong(file.length())
                            file.inputStream().use { it.copyTo(output, 256 * 1024) }
                        } else {
                            output.writeLong(-1L)
                        }
                        output.flush()
                    }

                    FILE_PUSH -> {
                        val file = resolve(root, readString(input))
                        val size = input.readLong()
                        file.parentFile?.mkdirs()
                        FileOutputStream(file).use { out ->
                            var remaining = size
                            val buffer = ByteArray(256 * 1024)
                            while (remaining > 0) {
                                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                                if (read < 0) throw IllegalStateException("上传意外中断")
                                out.write(buffer, 0, read)
                                remaining -= read
                            }
                        }
                        output.writeBoolean(true)
                        output.flush()
                    }

                    FILE_MKDIR -> {
                        val created = resolve(root, readString(input)).mkdirs()
                        output.writeBoolean(created)
                        output.flush()
                    }

                    FILE_PASTE -> {
                        val file = resolve(root, readString(input))
                        val result = if (file.isFile) ClipPaste.paste(this, file) else ""
                        writeString(output, result ?: "")
                    }

                    FILE_PASTE_TARGET -> writeString(output, RichPaste.target().toString())

                    FILE_SHARE_ATTACHMENTS -> {
                        val result = try {
                            val paths = JSONObject(readString(input)).getJSONArray("paths")
                            require(paths.length() in 1..32) { "一次最多分享32个文件" }
                            AttachmentShare.prepare(this, (0 until paths.length()).map {
                                resolve(root, paths.getString(it))
                            })
                        } catch (error: Throwable) {
                            BridgeEvents.log("w", "附件分享失败：${error.message}")
                            JSONObject().put("status", "failed").put("message", "无法准备附件分享，请检查手机通知和文件权限")
                        }
                        writeString(output, result.toString())
                    }

                    FILE_PASTE_RICH -> {
                        val request = JSONObject(readString(input))
                        val result = try {
                            val paths = request.getJSONArray("paths")
                            require(paths.length() in 1..32) { "一次最多粘贴32个文件" }
                            val files = (0 until paths.length()).map { resolve(root, paths.getString(it)) }
                            RichPaste.paste(this, files, request)
                        } catch (error: Throwable) {
                            BridgeEvents.log("w", "附件粘贴失败：${error.message}")
                            JSONObject().put("status", "failed").put("accepted", 0)
                                .put("total", request.optJSONArray("paths")?.length() ?: 0)
                                .put("clipboardReady", false).put("message", "附件粘贴失败，请检查手机连接与文件权限")
                        }
                        writeString(output, result.toString())
                    }

                    else -> {
                        BridgeEvents.log("w", "未知文件操作: $op")
                        return
                    }
                }
            }
        } catch (_: Throwable) {
            // Peer hung up.
        } finally {
            closeQuietly(socket)
        }
    }

    /** 4-byte big-endian length + standard UTF-8, mirroring the Dart client. */
    private fun readString(input: DataInputStream): String {
        val length = input.readInt()
        if (length < 0 || length > 1 shl 20) throw IllegalStateException("字符串长度非法: $length")
        val bytes = ByteArray(length)
        input.readFully(bytes)
        return String(bytes, Charsets.UTF_8)
    }

    private fun writeString(output: DataOutputStream, value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        output.writeInt(bytes.size)
        output.write(bytes)
        output.flush()
    }

    private fun shareRoot(): File {
        return if (hasAllFilesAccess()) {
            Environment.getExternalStorageDirectory()
        } else {
            getExternalFilesDir(null) ?: filesDir
        }
    }

    /** Confines every file operation to the shared root. */
    private fun resolve(root: File, path: String): File {
        // Relative paths ("Download/DexLink/a.png") are resolved inside the
        // root, so the PC never has to know where the root actually is.
        val candidate = if (path.isEmpty()) {
            root
        } else {
            val direct = File(path)
            if (direct.isAbsolute) direct else File(root, path)
        }
        val canonicalRoot = root.canonicalFile
        val canonical = candidate.canonicalFile
        if (canonical != canonicalRoot && !canonical.path.startsWith(canonicalRoot.path + File.separator)) {
            throw SecurityException("路径越界: $path")
        }
        return canonical
    }

    private fun listJson(dir: File): String {
        val items = JSONArray()
        val children = dir.listFiles()?.sortedWith(
            compareBy({ !it.isDirectory }, { it.name.lowercase() }),
        ) ?: emptyList()
        for (child in children) {
            items.put(
                JSONObject()
                    .put("name", child.name)
                    .put("path", child.absolutePath)
                    .put("dir", child.isDirectory)
                    .put("size", if (child.isFile) child.length() else 0L)
                    .put("modified", child.lastModified()),
            )
        }
        return JSONObject()
            .put("path", dir.absolutePath)
            .put("parent", if (dir.canonicalFile == shareRoot().canonicalFile) "" else dir.parent)
            .put("entries", items)
            .toString()
    }

    // ----------------------------------------------------- privileged capture

    private fun startCapture(width: Int, height: Int, dpi: Int, bitrate: Int, desktop: Boolean) {
        val token = UUID.randomUUID().toString() + UUID.randomUUID().toString()
        val listener = ServerSocket(0, 2, InetAddress.getByName("127.0.0.1"))
        captureListener = listener
        listener.soTimeout = 500
        try {
            val process = newShellProcess(arrayOf(
                "/system/bin/app_process",
                "-Djava.class.path=${applicationInfo.sourceDir}",
                "/",
                "io.dexlink.dex_phone.capture.CaptureMain",
                listener.localPort.toString(), token, desktop.toString(),
                width.toString(), height.toString(), dpi.toString(), bitrate.toString(),
                "direct",
            ))
            serverProcess = process
            consume(process.inputStream, "i")
            consume(process.errorStream, "e")
            thread(name = "dexlink-capture-exit") {
                try {
                    val code = process.waitFor()
                    if (!stopping.get() && serverProcess === process && isRunning) {
                        if (code == 0) {
                            BridgeEvents.log("i", "电脑端已断开")
                            stopSession("电脑端已断开")
                        } else fail("DexLink 采集已退出（$code），请查看运行日志")
                    }
                } catch (_: RuntimeException) {
                    // A dead Shizuku binder is handled by channel shutdown.
                }
            }
            val deadline = android.os.SystemClock.elapsedRealtime() + 15_000L
            while (videoSocket == null || controlSocket == null) {
                if (stopping.get()) throw IllegalStateException("会话已停止")
                if (!ProcessCleanup.isRunning(process)) throw IllegalStateException("DexLink 采集进程启动失败，请查看日志")
                if (android.os.SystemClock.elapsedRealtime() >= deadline) throw IllegalStateException("DexLink 采集连接超时（15 秒）")
                val socket = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                socket.soTimeout = 2000
                socket.tcpNoDelay = true
                try {
                    val input = DataInputStream(socket.getInputStream())
                    if (input.readUTF() != token) throw SecurityException("采集通道认证失败")
                    when (input.readUnsignedByte()) {
                        CHANNEL_VIDEO -> if (videoSocket == null) videoSocket = socket else socket.close()
                        CHANNEL_CONTROL -> if (controlSocket == null) controlSocket = socket else socket.close()
                        else -> socket.close()
                    }
                    socket.soTimeout = 0
                } catch (error: Exception) {
                    closeQuietly(socket)
                    BridgeEvents.log("w", "拒绝无效采集连接：${error.message}")
                }
            }
            videoSocket!!.soTimeout = 15_000
            val ready = DataInputStream(videoSocket!!.getInputStream())
            check(ready.readUnsignedByte() == 3) { "DexLink 采集初始化失败" }
            directPort = ready.readInt()
            check(directPort in 1..65535) { "DexLink 采集端口无效" }
            directToken = token
            videoSocket!!.soTimeout = 0
        } finally {
            closeQuietly(listener)
            captureListener = null
        }
    }

    /**
     * `Shizuku.newProcess()` is a public-in-spirit but `private`-declared API: it
     * forks a process running as the `shell` user. There is no supported
     * alternative that lets us exec `/system/bin/app_process`, so this reaches
     * for it reflectively and fails loudly if the signature ever moves.
     */
    private fun newShellProcess(command: Array<String>): Process {
        val method = Shizuku::class.java.getDeclaredMethod(
            "newProcess",
            Array<String>::class.java,
            Array<String>::class.java,
            String::class.java,
        )
        method.isAccessible = true
        // Explicit spread: `Method.invoke` is `(Object, Object...)`, and passing an
        // Array<String> as a plain argument would be ambiguous.
        return method.invoke(null, *arrayOf<Any?>(command, null, null)) as Process
    }

    private fun bindTcp(): ServerSocket? {
        for (candidate in port..(port + 9)) {
            try {
                val server = ServerSocket()
                server.reuseAddress = true
                server.bind(InetSocketAddress(candidate))
                port = candidate
                return server
            } catch (_: Throwable) {
                continue
            }
        }
        return null
    }

    /**
     * Answers the PC's LAN discovery broadcast, so the user never types an IP.
     * The reply carries the TCP port actually bound, which may differ from the
     * default if it was taken.
     */
    private fun startDiscovery() {
        thread(name = "dexlink-discovery") {
            try {
                val socket = DatagramSocket(null)
                socket.reuseAddress = true
                socket.broadcast = true
                socket.bind(InetSocketAddress(DISCOVERY_PORT))
                discoverySocket = socket
                val buffer = ByteArray(1024)
                while (!socket.isClosed) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    val request = String(packet.data, 0, packet.length, Charsets.UTF_8)
                    if (request.trim() != DISCOVERY_REQUEST) continue
                    val name = (Build.MODEL ?: "Android").replace("\"", "")
                    val reply = """DEXLINK/1 {"proto":1,"name":"$name","port":$port}"""
                    val bytes = reply.toByteArray(Charsets.UTF_8)
                    socket.send(DatagramPacket(bytes, bytes.size, packet.address, packet.port))
                }
            } catch (_: Throwable) {
                // Discovery is best effort; the user can still type the address.
            }
        }
    }

    private fun consume(stream: InputStream, level: String) {
        thread(name = "dexlink-log") {
            try {
                stream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (line.isNotBlank()) BridgeEvents.log(level, line.trim())
                    }
                }
            } catch (_: Throwable) {
                // Process torn down.
            }
        }
    }

    // ------------------------------------------------------------------ state

    private fun fail(message: String) {
        if (stopping.get()) return
        BridgeEvents.log("e", message)
        lastError = message
        isRunning = false
        BridgeEvents.status()
        stopSelf()
    }

    private fun stopSession(
        reason: String?,
        fromDestroy: Boolean = false,
    ) {
        if (!stopping.compareAndSet(false, true)) return
        if (!fromDestroy) lastError = reason
        isRunning = false
        mirrorEngine = "none"
        closeQuietly(captureListener)
        closeQuietly(tcpServer)
        closeQuietly(videoSocket)
        closeQuietly(controlSocket)
        controlTranslator?.stop()
        controlTranslator = null
        mirrorEncoder?.stop(releaseProjection = true)
        mirrorEncoder = null
        discoverySocket?.close()
        discoverySocket = null
        val process = serverProcess
        serverProcess = null
        if (process != null) {
            // Lifecycle callbacks must not block on the remote process proxy.
            thread(name = "dexlink-stop-process") { ProcessCleanup.terminate(process) }
        }
        videoSocket = null
        controlSocket = null
        directPort = 0
        directToken = null
        tcpServer = null
        BridgeEvents.status()
        if (!fromDestroy) stopSelf()
        // This service instance is finished. Late socket callbacks must not
        // publish another stop/error after the next instance has started.
    }

    private fun closeQuietly(closeable: java.io.Closeable?) {
        try {
            closeable?.close()
        } catch (_: Throwable) {
            // Already closed.
        }
    }

    private fun startInForeground(text: String, projection: Boolean = false) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "DexLink 会话", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("DexLink")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_dexlink)
            .setOngoing(true)
            .build()
        if (projection && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}
