package io.dexlink.dex_phone

import rikka.shizuku.Shizuku
import moe.shizuku.server.IShizukuService

/**
 * Thin wrapper around Shizuku.
 *
 * Shizuku is what makes the "no PC, no root" story possible: it is an Android
 * app that boots a process running as the `shell` user (uid 2000) by abusing the
 * device's own wireless-debugging endpoint, and it lends that privileged process
 * to other apps through a binder API. Everything DexLink needs for desktop mode
 * -- creating a virtual display, launching apps onto it, injecting input into
 * it -- requires exactly those shell privileges.
 */
object ShizukuSupport {
    const val REQUEST_CODE = 0x5D

    fun isAvailable(): Boolean = try {
        Shizuku.pingBinder()
    } catch (t: Throwable) {
        false
    }

    fun hasPermission(): Boolean = try {
        // The SDK caches a granted result for the lifetime of this process.
        // Ask the server again so a stale grant cannot enable the UI or skip
        // the authorization dialog after permission changes.
        isAvailable() && IShizukuService.Stub.asInterface(Shizuku.getBinder())
            .checkSelfPermission()
    } catch (t: Throwable) {
        false
    }

    fun version(): String? = try {
        if (isAvailable()) Shizuku.getVersion().toString() else null
    } catch (t: Throwable) {
        null
    }

    fun requestPermission() {
        check(isAvailable()) { "Shizuku 尚未连接，请先启动 Shizuku 后返回本应用" }
        if (hasPermission()) return
        Shizuku.requestPermission(REQUEST_CODE)
    }
}
