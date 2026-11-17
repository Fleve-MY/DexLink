package io.dexlink.dex_phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject
import java.io.File

/** Explicit fallback for editors which cannot receive rich content. */
object AttachmentShare {
    private const val CHANNEL = "dexlink_attachment_share"
    private const val NOTIFICATION = 27193

    fun intent(context: Context, files: List<File>): Intent {
        require(files.size in 1..32) { "一次最多分享32个文件" }
        val uris = files.map { AttachmentProvider.publish(context, it) }
        val mimes = files.map { AttachmentProvider.mime(it) }.distinct()
        val mime = if (mimes.size == 1) mimes.first() else {
            val types = mimes.map { it.substringBefore('/') }.distinct()
            if (types.size == 1) "${types.first()}/*" else "*/*"
        }
        val clip = ClipData("DexLink 附件", mimes.toTypedArray(), ClipData.Item(uris.first()))
        uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
        val send = Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE)
            .setType(mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (uris.size == 1) send.putExtra(Intent.EXTRA_STREAM, uris.first())
        else send.putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        send.clipData = clip
        return Intent.createChooser(send, "分享附件").apply {
            clipData = clip
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    fun prepare(context: Context, files: List<File>): JSONObject {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return result("notificationsDisabled", "请先允许手机 DexLink 的通知，再重试分享")
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "附件分享", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                enableVibration(false)
            })
            if (manager.getNotificationChannel(CHANNEL).importance == NotificationManager.IMPORTANCE_NONE) {
                return result("notificationsDisabled", "请先允许手机 DexLink 的附件分享通知")
            }
        }
        // A notification tap is a system-recognized user action. Do not attempt
        // a background activity launch or send to a guessed application.
        val pending = PendingIntent.getActivity(context, NOTIFICATION, intent(context, files),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(context)
        builder.setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("分享附件")
            .setContentText("${files.size} 个文件 · 点击选择接收应用")
            .setContentIntent(pending).setAutoCancel(true)
            .setOnlyAlertOnce(true).setDefaults(0)
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(10 * 60 * 1000L)
        manager.notify(NOTIFICATION, builder.build())
        return result("shareReady", "请在手机通知中点击“分享附件”")
    }

    private fun result(status: String, message: String) =
        JSONObject().put("status", status).put("message", message)
}
