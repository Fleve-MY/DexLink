package io.dexlink.dex_phone

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID

/** Read-only, grant-scoped attachment URIs; never expose arbitrary storage paths. */
class AttachmentProvider : ContentProvider() {
    companion object {
        private const val STORE = "dexlink_attachments"
        private const val MAX_AGE = 24 * 60 * 60 * 1000L
        private const val MAX_ITEMS = 256

        fun mime(file: File): String =
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
                ?: "application/octet-stream"

        @Synchronized
        fun publish(context: Context, file: File): Uri {
            val canonical = file.canonicalFile
            require(canonical.isFile && allowed(context, canonical)) { "文件不在粘贴接收目录" }
            val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val entries = prefs.all.entries.mapNotNull { entry ->
                runCatching {
                    entry.key to JSONObject(entry.value as String).getLong("created")
                }.getOrNull()
            }.sortedBy { it.second }
            val edit = prefs.edit()
            entries.filter { now - it.second > MAX_AGE }.forEach { edit.remove(it.first) }
            entries.filter { now - it.second <= MAX_AGE }
                .dropLast(MAX_ITEMS - 1).forEach { edit.remove(it.first) }
            val token = UUID.randomUUID().toString()
            check(edit.putString(token, JSONObject().put("path", canonical.path)
                .put("created", now).toString()).commit()) { "附件索引无法保存" }
            return Uri.Builder().scheme("content").authority("${context.packageName}.attachments")
                .appendPath(token).appendPath(canonical.name).build()
        }

        private fun allowed(context: Context, file: File): Boolean {
            val roots = listOfNotNull(
                File(Environment.getExternalStorageDirectory(), "Download/DexLink"),
                context.getExternalFilesDir(null)?.let { File(it, "Download/DexLink") },
                File(context.filesDir, "Download/DexLink"),
            )
            return roots.any { file.path.startsWith(it.canonicalPath + File.separator) }
        }
    }

    override fun onCreate() = true

    private fun resolve(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException()
        if (uri.authority != "${ctx.packageName}.attachments" || uri.pathSegments.size != 2) {
            throw FileNotFoundException("Invalid attachment URI")
        }
        val stored = ctx.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .getString(uri.pathSegments[0], null) ?: throw FileNotFoundException("Unknown attachment")
        val entry = JSONObject(stored)
        if (System.currentTimeMillis() - entry.getLong("created") > MAX_AGE) {
            throw FileNotFoundException("Attachment expired")
        }
        val file = File(entry.getString("path")).canonicalFile
        if (!file.isFile || !allowed(ctx, file) || file.name != uri.lastPathSegment) {
            throw FileNotFoundException("Attachment unavailable")
        }
        return file
    }

    override fun getType(uri: Uri) = mime(resolve(uri))

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = resolve(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply {
            addRow(columns.map<String, Any?> { when (it) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> file.length()
                else -> null
            } }.toTypedArray())
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Attachments are read-only")
        return ParcelFileDescriptor.open(resolve(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
}
