package io.dexlink.dex_phone

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {

    private companion object {
        const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        const val NIGHTZUKU_PACKAGE = "kerneldroid.nightzuku"
        const val SHIZUKU_DOWNLOAD = "https://shizuku.rikka.app/download/"
        const val ADB_WIFI_ENABLED = "adb_wifi_enabled"
        const val REQUEST_CAPTURE = 0x5E

        val CELLULAR_PREFIXES =
            listOf("rmnet", "ccmni", "pdp", "wwan", "clat", "dummy", "tun", "ppp")
    }

    private var sink: EventChannel.EventSink? = null
    private var awaitingShizuku = false

    private val eventListener: (String) -> Unit = { json ->
        runOnUiThread { sink?.success(json) }
    }

    private val permissionListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode == ShizukuSupport.REQUEST_CODE) {
                BridgeEvents.log("i", "Shizuku 授权回调=$grantResult，服务端复核=${ShizukuSupport.hasPermission()}")
                emitShizukuState()
            }
        }

    // Shizuku can be started or killed while this screen is open (the user is
    // sent to the Shizuku app to activate it), so the UI follows the binder
    // instead of relying on a manual "refresh".
    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {
        runOnUiThread {
            emitShizukuState()
            requestPendingShizukuPermission()
        }
    }
    private val binderDeadListener = Shizuku.OnBinderDeadListener { emitShizukuState() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            Shizuku.addRequestPermissionResultListener(permissionListener)
            Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
            Shizuku.addBinderDeadListener(binderDeadListener)
        } catch (_: Throwable) {
            // Shizuku is not installed; the UI explains that.
        }
    }

    override fun onDestroy() {
        try {
            Shizuku.removeRequestPermissionResultListener(permissionListener)
            Shizuku.removeBinderReceivedListener(binderReceivedListener)
            Shizuku.removeBinderDeadListener(binderDeadListener)
        } catch (_: Throwable) {
            // Nothing to unwire.
        }
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        emitShizukuState()
        requestPendingShizukuPermission()
    }

    private fun requestPendingShizukuPermission() {
        if (!awaitingShizuku || !ShizukuSupport.isAvailable() || isFinishing) return
        awaitingShizuku = false
        try {
            ShizukuSupport.requestPermission()
        } catch (error: Throwable) {
            BridgeEvents.log("e", error.message ?: "Shizuku 授权请求失败")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "io.dexlink/phone/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    BridgeEvents.add(eventListener)
                    events?.success(statusJson())
                    emitShizukuState()
                }

                override fun onCancel(arguments: Any?) {
                    BridgeEvents.remove(eventListener)
                    sink = null
                }
            },
        )

        MethodChannel(messenger, "io.dexlink/phone").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(statusMap())

                "requestShizuku" -> {
                    try {
                        ShizukuSupport.requestPermission()
                        emitShizukuState()
                        result.success(null)
                    } catch (error: Throwable) {
                        result.error("SHIZUKU_PERMISSION", error.message, null)
                    }
                }

                "openShizuku" -> {
                    awaitingShizuku = true
                    openShizukuApp()
                    result.success(null)
                }

                "screenShareProtectionConfirmed" -> result.success(
                    getPreferences(MODE_PRIVATE).getBoolean("screenShareProtectionConfirmed", false),
                )

                "confirmScreenShareProtection" -> {
                    getPreferences(MODE_PRIVATE).edit()
                        .putBoolean("screenShareProtectionConfirmed", call.arguments == true)
                        .apply()
                    result.success(null)
                }

                "openDeveloperOptions" -> {
                    openDeveloperSettings()
                    result.success(null)
                }

                "openWirelessDebugging" -> {
                    openWirelessDebugging()
                    result.success(null)
                }

                "openAccessibility" -> {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }

                "openRichInputSettings" -> {
                    startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }

                "chooseRichInput" -> {
                    getSystemService(android.view.inputmethod.InputMethodManager::class.java)
                        .showInputMethodPicker()
                    result.success(null)
                }

                "openAppSettings" -> {
                    // Some ROMs block accessibility for sideloaded apps and only
                    // expose the "allow restricted settings" toggle from here.
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    } catch (_: Throwable) {
                        startActivity(
                            Intent(Settings.ACTION_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    }
                    result.success(null)
                }

                "startMirror" -> {
                    if (ShizukuSupport.isAvailable() && ShizukuSupport.hasPermission()) {
                        BridgeEvents.log("i", "检测到 Shizuku 已授权，使用增强镜像通道")
                        val intent = Intent(this, BridgeService::class.java)
                            .setAction(BridgeService.ACTION_START)
                            .putExtra(BridgeService.EXTRA_MODE, BridgeService.MODE_MIRROR)
                            .putExtra(BridgeService.EXTRA_NEW_DISPLAY, false)
                            .putExtra(BridgeService.EXTRA_BITRATE, 24_000_000)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    val manager = getSystemService(MediaProjectionManager::class.java)
                    // Android 14 defaults to "let the user share a single app".
                    // A single-app projection would break pointer mapping (the
                    // app window is not the screen) and could not be navigated
                    // out of, so ask for the whole display explicitly.
                    val captureIntent =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            manager.createScreenCaptureIntent(
                                MediaProjectionConfig.createConfigForDefaultDisplay(),
                            )
                        } else {
                            manager.createScreenCaptureIntent()
                        }
                    startActivityForResult(captureIntent, REQUEST_CAPTURE)
                    result.success(true)
                }

                "start" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    startSession(args)
                    result.success(true)
                }

                "stop" -> {
                    startService(
                        Intent(this, BridgeService::class.java).setAction(BridgeService.ACTION_STOP),
                    )
                    result.success(true)
                }

                "openAllFilesAccess" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            .setData(Uri.parse("package:$packageName"))
                        startActivity(intent)
                    }
                    result.success(null)
                }

                "openScreenShareProtection" -> {
                    openScreenShareProtection()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_CAPTURE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val intent = Intent(this, BridgeService::class.java)
                    .setAction(BridgeService.ACTION_START)
                    .putExtra(BridgeService.EXTRA_MODE, BridgeService.MODE_MIRROR)
                    .putExtra(BridgeService.EXTRA_RESULT_CODE, resultCode)
                    .putExtra(BridgeService.EXTRA_PROJECTION_DATA, data)
                    .putExtra(BridgeService.EXTRA_BITRATE, 24_000_000)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
            } else {
                BridgeEvents.log("w", "已取消录屏授权，镜像没有启动")
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    // ------------------------------------------------------------ onboarding

    private fun emitShizukuState() {
        val json = """{"type":"shizuku","installed":${isManagerInstalled()},"managerName":${jsonString(managerName())},""" +
            """"running":${ShizukuSupport.isAvailable()},"granted":${ShizukuSupport.hasPermission()},""" +
            """"adbEnabled":${globalFlag(Settings.Global.ADB_ENABLED)},""" +
            """"wirelessDebugging":${globalFlag(ADB_WIFI_ENABLED)}}"""
        runOnUiThread { sink?.success(json) }
    }

    private fun isPackageInstalled(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0)
        true
    } catch (_: Throwable) {
        false
    }

    /** Reads a `Settings.Global` boolean; some ROMs forbid individual keys. */
    private fun globalFlag(key: String): Boolean = try {
        Settings.Global.getInt(contentResolver, key, 0) == 1
    } catch (_: Throwable) {
        false
    }

    private fun openShizukuApp() {
        val launch = packageManager.getLaunchIntentForPackage(managerPackage())
        if (launch != null) {
            startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        // Not installed: send the user to the official download page.
        startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(SHIZUKU_DOWNLOAD))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    private fun isManagerInstalled(): Boolean =
        isPackageInstalled(SHIZUKU_PACKAGE) || isPackageInstalled(NIGHTZUKU_PACKAGE)

    private fun managerPackage(): String =
        if (isPackageInstalled(NIGHTZUKU_PACKAGE) &&
            (Build.VERSION.SDK_INT >= 37 || !isPackageInstalled(SHIZUKU_PACKAGE))) {
            NIGHTZUKU_PACKAGE
        } else {
            SHIZUKU_PACKAGE
        }

    private fun managerName(): String =
        if (managerPackage() == NIGHTZUKU_PACKAGE) "Nightzuku" else "Shizuku"

    private fun openDeveloperSettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Throwable) {
            startActivity(
                Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /**
     * Sends the user towards `设置 → 安全 → 电诈防护 → 屏幕共享防护`.
     *
     * HyperOS has no public intent for that page, so this walks a short list of
     * known entry points and always lands somewhere useful.
     */
    private fun openScreenShareProtection() {
        val candidates = listOf(
            Intent().setClassName(
                "com.miui.securitycenter",
                "com.miui.antifraud.activity.AntiFraudActivity",
            ),
            Intent("miui.intent.action.ANTI_FRAUD"),
            Intent().setClassName(
                "com.miui.securitycenter",
                "com.miui.securitycenter.MainActivity",
            ),
        )
        for (intent in candidates) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Throwable) {
                continue
            }
        }
        try {
            startActivity(
                Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Throwable) {
            // Nothing left to try.
        }
    }

    private fun openWirelessDebugging() {
        // There is no public constant for this screen, so try the known intents
        // in order and fall back to the developer-options list.
        val candidates = listOf(
            Intent("android.settings.WIRELESS_DEBUGGING"),
            Intent().setClassName(
                "com.android.settings",
                "com.android.settings.Settings\$WirelessDebuggingActivity",
            ),
        )
        for (intent in candidates) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Throwable) {
                continue
            }
        }
        openDeveloperSettings()
    }

    // --------------------------------------------------------------- session

    private fun startSession(args: Map<*, *>) {
        val intent = Intent(this, BridgeService::class.java)
            .setAction(BridgeService.ACTION_START)
            .putExtra(BridgeService.EXTRA_WIDTH, (args["width"] as? Int) ?: 1920)
            .putExtra(BridgeService.EXTRA_HEIGHT, (args["height"] as? Int) ?: 1080)
            .putExtra(BridgeService.EXTRA_DPI, (args["dpi"] as? Int) ?: 160)
            .putExtra(BridgeService.EXTRA_BITRATE, (args["bitrate"] as? Int) ?: 12_000_000)
            .putExtra(BridgeService.EXTRA_NEW_DISPLAY, (args["newDisplay"] as? Boolean) ?: true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "shizukuInstalled" to isManagerInstalled(),
        "managerName" to managerName(),
        "shizukuAvailable" to ShizukuSupport.isAvailable(),
        "shizukuGranted" to ShizukuSupport.hasPermission(),
        "mirrorEngine" to if (BridgeService.isRunning) BridgeService.mirrorEngine else "none",
        "shizukuVersion" to ShizukuSupport.version(),
        "adbEnabled" to globalFlag(Settings.Global.ADB_ENABLED),
        "wirelessDebugging" to globalFlag(ADB_WIFI_ENABLED),
        "running" to BridgeService.isRunning,
        "mode" to BridgeService.runningMode,
        "port" to BridgeService.port,
        "size" to BridgeService.displaySize,
        "error" to BridgeService.lastError,
        "addresses" to addresses(),
        "allFiles" to BridgeService.hasAllFilesAccess(),
        "accessibility" to DexAccessibilityService.isEnabled(this),
        "manufacturer" to Build.MANUFACTURER,
        "sdk" to Build.VERSION.SDK_INT,
        "richInputEnabled" to DexInputMethodService.enabled(this),
        "richInputSelected" to DexInputMethodService.selected(this),
    )

    private fun statusJson(): String {
        val addressJson = addresses().joinToString(",") { address ->
            """{"iface":"${address["iface"]}","ip":"${address["ip"]}","usb":${address["usb"]}}"""
        }
        return """{"type":"state","running":${BridgeService.isRunning},"port":${BridgeService.port},""" +
            """"size":"${BridgeService.displaySize}","error":${jsonString(BridgeService.lastError ?: "")},""" +
            """"addresses":[$addressJson]}"""
    }

    private fun jsonString(value: String): String =
        "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    private fun addresses(): List<Map<String, Any>> {
        val result = mutableListOf<Map<String, Any>>()
        try {
            for (networkInterface in NetworkInterface.getNetworkInterfaces()) {
                if (!networkInterface.isUp || networkInterface.isLoopback) continue
                val name = networkInterface.name
                // Cellular interfaces are reachable from the carrier, never from
                // the PC. Showing them only confuses the user.
                if (CELLULAR_PREFIXES.any { name.startsWith(it) }) continue
                val isUsb = name.startsWith("rndis") || name.startsWith("usb") || name == "eth0"
                for (address in networkInterface.inetAddresses) {
                    val ipv4 = address as? Inet4Address ?: continue
                    if (ipv4.isLoopbackAddress) continue
                    result.add(
                        mapOf(
                            "iface" to name,
                            "ip" to (ipv4.hostAddress ?: continue),
                            "usb" to isUsb,
                        ),
                    )
                }
            }
        } catch (_: Throwable) {
            // Enumeration is best effort.
        }
        return result
    }
}
