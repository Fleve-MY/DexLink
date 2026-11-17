package io.dexlink.dex_phone.capture;

import android.content.Context;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.LinkedHashMap;

/** Session-scoped window handles and geometry. Never exposes Android task IDs. */
final class DesktopAppWindows implements AutoCloseable {
    private final Context context;
    private final DisplayManager displays;
    private final int width, height, fps;
    private int sequence, focused;
    private final LinkedHashMap<Integer, Window> windows = new LinkedHashMap<>();

    private static final class Window {
        int id;
        String component, label;
        Rect bounds, restore;
        boolean minimized;
        String layout = AppDisplayProfile.TABLET;
        int viewportWidth, viewportHeight;
        AppWindowCapture capture;
    }

    DesktopAppWindows(Context context, DisplayManager displays, int width, int height, int fps) {
        this.context = context;
        this.displays = displays;
        this.width = width;
        this.height = height;
        this.fps = fps;
    }

    synchronized void launch(String component) throws Exception {
        launch(component, AppDisplayProfile.TABLET);
    }

    synchronized void launch(String component, String layout) throws Exception {
        for (Window window : windows.values()) {
            if (window.component.equals(component) && window.capture.alive()) {
                focus(window);
                return;
            }
        }
        // Hardware encoder capacity varies. Bound allocation and report a
        // refusal rather than silently falling back to OEM freeform geometry.
        if (windows.size() >= 3) throw new IllegalStateException("最多同时打开三个应用窗口，请先关闭一个窗口");
        Window window = new Window();
        window.id = ++sequence;
        window.component = component;
        android.content.ComponentName name = android.content.ComponentName.unflattenFromString(component);
        window.label = context.getPackageManager().getActivityInfo(name, 0).loadLabel(context.getPackageManager()).toString();
        int w = Math.min(960, width - 160), h = Math.min(700, height - 140);
        int offset = ((sequence - 1) % 3) * 36;
        int x = Math.max(0, Math.min(width - w, (width - w) / 2 + offset));
        int y = Math.max(40, Math.min(height - h, (height - h) / 2 + offset));
        window.bounds = new Rect(x, y, x + w, y + h);
        window.viewportWidth = pixels(w, 2880);
        window.viewportHeight = pixels(h, 2160);
        window.capture = new AppWindowCapture(context, displays, component, fps, window.viewportWidth, window.viewportHeight, layout);
        window.layout = layout;
        windows.put(window.id, window);
        focus(window);
    }

    private void focus(Window window) {
        focused = window.id;
        window.minimized = false;
        window.capture.setVisible(true);
        // Insertion order is our z order, independent of OEM task ordering.
        windows.remove(window.id);
        windows.put(window.id, window);
    }

    synchronized void home() {
        for (Window window : windows.values()) {
            window.minimized = true;
            window.capture.setVisible(false);
        }
        focused = 0;
    }

    synchronized void handle(JSONObject request) throws Exception {
        String action = request.getString("action");
        if (action.equals("home")) { home(); return; }
        Window window = windows.get(request.getInt("taskId"));
        if (window == null) throw new IllegalArgumentException("窗口不属于当前会话或已经关闭");
        switch (action) {
            case "close":
                windows.remove(window.id);
                window.capture.close();
                if (focused == window.id) focused = 0;
                return;
            case "minimize":
                window.minimized = true;
                window.capture.setVisible(false);
                if (focused == window.id) focused = 0;
                return;
            case "focus": focus(window); return;
            case "resizeContent":
                resize(window, request.getInt("width"), request.getInt("height"), window.layout);
                return;
            case "layout":
                resize(window, window.viewportWidth, window.viewportHeight, request.getString("layout"));
                return;
            case "bounds": {
                int w = Math.max(Math.min(320, width), Math.min(width, request.getInt("width")));
                int h = Math.max(Math.min(240, height - 40), Math.min(height - 40, request.getInt("height")));
                int x = Math.max(0, Math.min(width - w, request.getInt("x")));
                int y = Math.max(40, Math.min(height - h, request.getInt("y")));
                window.bounds = new Rect(x, y, x + w, y + h);
                window.restore = new Rect(window.bounds);
                break;
            }
            case "maximize": case "left": case "right":
                if (window.restore == null) window.restore = new Rect(window.bounds);
                window.bounds = action.equals("left") ? new Rect(0, 40, width / 2, height)
                        : action.equals("right") ? new Rect(width / 2, 40, width, height)
                        : new Rect(0, 40, width, height);
                break;
            case "restore":
                if (window.restore != null) window.bounds = new Rect(window.restore);
                window.restore = null;
                break;
            default: throw new IllegalArgumentException("未知窗口操作");
        }
        // New PC clients send the exact content viewport after laying out chrome.
        // Do not restart the encoder with an intermediate logical size first.
        if (!request.optBoolean("clientViewport", false)) {
            resize(window, pixels(window.bounds.width(), 2880), pixels(window.bounds.height(), 2160), window.layout);
        }
        focus(window);
    }

    private static int pixels(int logical, int maximum) {
        return Math.max(240, Math.min(maximum, (int) Math.round(logical * 1.5))) & ~1;
    }

    private void resize(Window window, int width, int height, String layout) {
        // Validate before updating session metadata so rejected requests cannot
        // poison the layout selected for the next viewport resize.
        AppDisplayProfile.create(width, height, layout);
        window.capture.resize(width, height, layout);
        window.viewportWidth = width;
        window.viewportHeight = height;
        window.layout = layout;
    }

    synchronized JSONArray tasks() throws Exception {
        JSONArray result = new JSONArray();
        ArrayList<Window> ordered = new ArrayList<>(windows.values());
        java.util.Collections.reverse(ordered);
        for (Window window : ordered) {
            AppDisplayProfile profile = window.capture.profile();
            result.put(new JSONObject().put("id", window.id).put("kind", "appWindow")
                    .put("label", window.label).put("component", window.component)
                    .put("focused", focused == window.id).put("minimized", window.minimized)
                    .put("windowingMode", 5).put("bounds", window.bounds.toString())
                    .put("streamPort", window.capture.transport.port()).put("streamToken", window.capture.token)
                    .put("displayId", window.capture.displayId).put("contentWidth", profile.width)
                    .put("contentHeight", profile.height).put("layout", profile.layout)
                    .put("densityDpi", profile.density)
                    .put("smallestWidthDp", profile.smallestWidthDp())
                    .put("error", window.capture.error == null ? JSONObject.NULL : window.capture.error));
        }
        return result;
    }

    @Override public synchronized void close() {
        for (Window window : windows.values()) window.capture.close();
        windows.clear();
    }
}
