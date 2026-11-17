package io.dexlink.dex_phone

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.graphics.PointF
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The input side of mirror mode when running without Shizuku.
 */
class DexAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: DexAccessibilityService? = null
            private set

        /** Whether the user has switched this service on in Settings. */
        fun isEnabled(context: Context): Boolean {
            val expected = "${context.packageName}/${DexAccessibilityService::class.java.name}"
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            val splitter = TextUtils.SimpleStringSplitter(':')
            splitter.setString(enabled)
            while (splitter.hasNext()) {
                if (splitter.next().equals(expected, ignoreCase = true)) return true
            }
            return false
        }
    }

    private val gestureInFlight = AtomicBoolean(false)
    private val scrollLock = Any()
    private var pendingScrollX = 0f
    private var pendingScrollY = 0f
    private var pendingScrollDistance = 0f

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    fun tap(x: Float, y: Float) {
        val cx = x.coerceAtLeast(1f)
        val cy = y.coerceAtLeast(1f)
        val path = Path().apply {
            moveTo(cx, cy)
        }
        dispatch(path, 18L)
    }

    fun longPress(x: Float, y: Float) {
        val cx = x.coerceAtLeast(1f)
        val cy = y.coerceAtLeast(1f)
        val path = Path().apply {
            moveTo(cx, cy)
        }
        dispatch(path, 480L)
    }

    fun drag(points: List<PointF>, durationMs: Long) {
        if (points.isEmpty()) return
        if (points.size == 1) {
            tap(points[0].x, points[0].y)
            return
        }
        val simplified = simplifyPoints(points, maxWaypoints = 8)
        val path = Path().apply {
            moveTo(simplified[0].x.coerceAtLeast(1f), simplified[0].y.coerceAtLeast(1f))
        }
        for (index in 1 until simplified.size) {
            path.lineTo(
                simplified[index].x.coerceAtLeast(1f),
                simplified[index].y.coerceAtLeast(1f),
            )
        }
        dispatch(path, durationMs.coerceIn(45L, 220L))
    }

    private fun simplifyPoints(points: List<PointF>, maxWaypoints: Int): List<PointF> {
        if (points.size <= maxWaypoints) return points
        val out = ArrayList<PointF>(maxWaypoints)
        val lastIndex = points.size - 1
        for (i in 0 until maxWaypoints) {
            val idx = (i * lastIndex) / (maxWaypoints - 1)
            out.add(points[idx])
        }
        return out
    }

    /** Fling used to emulate a scroll wheel. [distance] > 0 scrolls content down. */
    fun scroll(x: Float, y: Float, distance: Float) {
        synchronized(scrollLock) {
            pendingScrollX = x
            pendingScrollY = y
            pendingScrollDistance = (pendingScrollDistance + distance).coerceIn(-1800f, 1800f)
        }
        flushPendingScroll()
    }

    private fun flushPendingScroll() {
        if (gestureInFlight.get()) return
        val x: Float
        val y: Float
        val clamped: Float
        synchronized(scrollLock) {
            if (kotlin.math.abs(pendingScrollDistance) < 20f) {
                pendingScrollDistance = 0f
                return
            }
            x = pendingScrollX.coerceAtLeast(1f)
            y = pendingScrollY.coerceAtLeast(1f)
            clamped = pendingScrollDistance.coerceIn(-1400f, 1400f)
            pendingScrollDistance = 0f
        }
        val targetY = (y - clamped).coerceAtLeast(1f)
        val path = Path().apply {
            moveTo(x, y)
            lineTo(x, targetY)
        }
        dispatch(path, 65L)
    }

    fun globalBack(): Boolean = performGlobalAction(GLOBAL_ACTION_BACK)

    fun globalHome(): Boolean = performGlobalAction(GLOBAL_ACTION_HOME)

    fun globalRecents(): Boolean = performGlobalAction(GLOBAL_ACTION_RECENTS)

    fun globalNotifications(): Boolean = performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)

    fun globalQuickSettings(): Boolean = performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)

    /** Replaces the current selection in the focused field with [text]. */
    fun typeText(text: String): Boolean {
        val node = focusedInput() ?: return false
        val existing = node.text?.toString() ?: ""
        val (low, high) = selection(node, existing)
        val updated = existing.substring(0, low) + text + existing.substring(high)
        return setText(node, updated)
    }

    /** Pastes the phone's clipboard into the focused input. */
    fun pasteIntoFocused(): Boolean {
        val node = focusedInput() ?: return false
        if (!node.isEditable) return false
        return node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
    }

    /** Deletes the selection, or one character before the cursor. */
    fun deleteBeforeCursor(): Boolean {
        val node = focusedInput() ?: return false
        val existing = node.text?.toString() ?: return false
        val (low, high) = selection(node, existing)
        val updated = if (low != high) {
            existing.substring(0, low) + existing.substring(high)
        } else {
            if (low == 0) return false
            existing.substring(0, low - 1) + existing.substring(low)
        }
        return setText(node, updated)
    }

    private fun focusedInput(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        return root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
    }

    private fun selection(node: AccessibilityNodeInfo, existing: String): Pair<Int, Int> {
        val rawStart = node.textSelectionStart
        val rawEnd = node.textSelectionEnd
        val start = if (rawStart < 0) existing.length else rawStart
        val end = if (rawEnd < 0) existing.length else rawEnd
        val low = minOf(start, end).coerceIn(0, existing.length)
        val high = maxOf(start, end).coerceIn(0, existing.length)
        return low to high
    }

    private fun setText(node: AccessibilityNodeInfo, value: String): Boolean {
        val arguments = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                value,
            )
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
    }

    private fun dispatch(path: Path, durationMs: Long) {
        try {
            val stroke = GestureDescription.StrokeDescription(
                path,
                0,
                durationMs.coerceIn(1, 60_000),
            )
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            gestureInFlight.set(true)
            val accepted = dispatchGesture(
                gesture,
                object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        gestureInFlight.set(false)
                        flushPendingScroll()
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        gestureInFlight.set(false)
                        flushPendingScroll()
                    }
                },
                null,
            )
            if (!accepted) {
                gestureInFlight.set(false)
            }
        } catch (_: Throwable) {
            gestureInFlight.set(false)
        }
    }
}
