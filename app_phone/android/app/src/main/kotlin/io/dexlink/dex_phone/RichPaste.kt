package io.dexlink.dex_phone

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** File workers prepare URIs; the current input connection is used only on main. */
object RichPaste {
    private fun <T> main(action: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return action()
        val task = FutureTask(action)
        Handler(Looper.getMainLooper()).post(task)
        return try {
            task.get(5, TimeUnit.SECONDS)
        } catch (error: Throwable) {
            // A delayed task must never paste into a field after the caller timed out.
            task.cancel(false)
            throw error
        }
    }

    fun target(): JSONObject = main {
        val ime = DexInputMethodService.instance
        JSONObject().put("token", ime?.editorToken ?: "")
            .put("package", ime?.targetPackage() ?: "")
            .put("display", ime?.targetDisplay() ?: -1)
    }

    fun paste(context: Context, files: List<File>, request: JSONObject): JSONObject {
        require(files.isNotEmpty() && files.size <= 32) { "一次最多粘贴32个文件" }
        require(files.all { it.isFile }) { "部分文件尚未上传完成" }
        val uris = files.map { AttachmentProvider.publish(context, it) }
        val mimes = files.map { AttachmentProvider.mime(it) }
        return main {
            val result = JSONObject().put("total", files.size).put("accepted", 0)
            val clip = ClipData(ClipDescription("DexLink", mimes.distinct().toTypedArray()), ClipData.Item(uris[0]))
            uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
            result.put("clipboardReady", true)
            val ime = DexInputMethodService.instance
            val token = request.optString("token")
            val expectedPackage = request.optString("package")
            val expectedDisplay = request.optInt("display", -1)
            if (ime == null || !DexInputMethodService.selected(context) || ime.editorToken.isNullOrEmpty()) {
                return@main result.put("status", "needsInputMethod")
                    .put("message", "已传到手机；请启用并选择“DexLink 输入辅助”后重新粘贴")
            }
            if (token.isEmpty() || token != ime.editorToken ||
                (expectedPackage.isNotEmpty() && expectedPackage != ime.targetPackage()) ||
                (expectedDisplay >= 0 && expectedDisplay != ime.targetDisplay())) {
                return@main result.put("status", "focusChanged")
                    .put("message", "输入框已切换，请点选目标输入框后重新粘贴")
            }
            // Preflight the whole batch; never turn unsupported files into path text.
            if (mimes.any { !ime.accepts(it) }) {
                return@main result.put("status", "unsupported")
                    .put("message", "当前输入框不支持这类附件；文件已传到手机")
            }
            var accepted = 0
            for (index in files.indices) {
                // Some editors move focus as soon as their attachment preview opens.
                if (ime.editorToken != token) break
                try {
                    if (!ime.commitAttachment(uris[index], mimes[index], files[index].name)) break
                    accepted++
                } catch (error: Throwable) {
                    BridgeEvents.log("w", "附件输入失败：${error.message}")
                    break
                }
            }
            result.put("accepted", accepted)
            when (accepted) {
                files.size -> result.put("status", "accepted")
                    .put("message", "已向输入框提交${accepted}个附件，请在应用中确认")
                0 -> result.put("status", "rejected")
                    .put("message", "应用未接受附件；文件已传到手机")
                else -> result.put("status", "partial")
                    .put("message", "已提交${accepted}/${files.size}个附件，请在应用中确认")
            }
        }
    }
}
