package io.dexlink.dex_phone

import android.content.ClipDescription
import android.content.ComponentName
import android.content.Context
import android.inputmethodservice.InputMethodService
import android.net.Uri
import android.provider.Settings
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputContentInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import java.util.UUID

/** Optional rich input bridge. Android alone binds this service after user selection. */
open class DexInputMethodService : InputMethodService() {
    companion object {
        @Volatile var instance: DexInputMethodService? = null
            private set

        private fun id(context: Context) = ComponentName(context, DexInputMethodService::class.java)
        fun enabled(context: Context): Boolean =
            context.getSystemService(InputMethodManager::class.java).enabledInputMethodList.any {
                ComponentName.unflattenFromString(it.id) == id(context)
            }
        fun selected(context: Context): Boolean = ComponentName.unflattenFromString(
            Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD) ?: "",
        ) == id(context)
    }

    var editorToken: String? = null
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        editorToken = UUID.randomUUID().toString()
    }

    override fun onFinishInput() {
        editorToken = null
        super.onFinishInput()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onCreateInputView(): View = Button(this).apply {
        text = "切换输入法"
        setOnClickListener { getSystemService(InputMethodManager::class.java).showInputMethodPicker() }
    }

    fun targetPackage(): String = currentInputEditorInfo?.packageName ?: ""

    fun targetDisplay(): Int = if (android.os.Build.VERSION.SDK_INT >= 30) {
        display?.displayId ?: 0
    } else 0

    fun accepts(mime: String): Boolean = currentInputEditorInfo?.contentMimeTypes
        ?.any { ClipDescription.compareMimeTypes(mime, it) } == true

    fun commitAttachment(uri: Uri, mime: String, name: String): Boolean {
        val input = currentInputConnection ?: return false
        val type = currentInputEditorInfo?.inputType ?: 0
        val variation = type and android.text.InputType.TYPE_MASK_VARIATION
        if (variation == android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
            variation == android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            ((type and android.text.InputType.TYPE_MASK_CLASS) == android.text.InputType.TYPE_CLASS_NUMBER &&
                variation == android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD)) return false
        if (!accepts(mime)) return false
        input.finishComposingText()
        return input.commitContent(
            InputContentInfo(uri, ClipDescription(name, arrayOf(mime)), null),
            InputConnection.INPUT_CONTENT_GRANT_READ_URI_PERMISSION, null,
        )
    }
}
