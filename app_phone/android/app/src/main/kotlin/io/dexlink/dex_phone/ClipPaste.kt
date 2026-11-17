package io.dexlink.dex_phone

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import java.io.File

/** Legacy single-file operation: publish a readable URI, never a path string. */
object ClipPaste {
    fun paste(context: Context, file: File): String? = try {
        val uri = AttachmentProvider.publish(context, file)
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(
            ClipData.newUri(context.contentResolver, file.name, uri),
        )
        uri.toString()
    } catch (error: Throwable) {
        BridgeEvents.log("w", "Clipboard attachment unavailable: ${error.message}")
        null
    }
}
