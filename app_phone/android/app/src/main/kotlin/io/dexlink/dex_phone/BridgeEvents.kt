package io.dexlink.dex_phone

import java.util.concurrent.CopyOnWriteArrayList

/** Minimal, dependency-free fan-out for status lines and log lines. */
object BridgeEvents {
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    fun add(listener: (String) -> Unit) {
        listeners.add(listener)
    }

    fun remove(listener: (String) -> Unit) {
        listeners.remove(listener)
    }

    fun emit(json: String) {
        for (listener in listeners) {
            try {
                listener(json)
            } catch (_: Throwable) {
                // A dead sink must never take the session down.
            }
        }
    }

    fun log(level: String, message: String) {
        android.util.Log.println(
            if (level == "e") android.util.Log.ERROR else if (level == "w") android.util.Log.WARN else android.util.Log.INFO,
            "DexLink", message,
        )
        emit("""{"type":"log","level":"$level","message":${quote(message)}}""")
    }

    fun status() {
        emit(
            """{"type":"state","running":${BridgeService.isRunning},"port":${BridgeService.port},""" +
                """"mirrorEngine":${quote(BridgeService.mirrorEngine)},"size":${quote(BridgeService.displaySize)},"error":${quote(BridgeService.lastError ?: "")}}"""
        )
    }

    private fun quote(value: String): String {
        val sb = StringBuilder("\"")
        for (c in value) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        return sb.append('"').toString()
    }
}
