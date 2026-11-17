package io.dexlink.dex_phone.capture;

import android.app.ActivityManager;
import android.app.ActivityOptions;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.graphics.Rect;
import android.os.Bundle;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;

/** Task operations are confined to this session's display, never display 0. */
@android.annotation.SuppressLint({"PrivateApi", "BlockedPrivateApi", "SoonBlockedPrivateApi"})
final class DesktopControl {
    static final String HOME = "io.dexlink.dex_phone/.DesktopActivity";
    private final Context context;
    private final int displayId, width, height;
    private final Object service;
    private final Class<?> api;
    private int cascade;
    private DesktopAppWindows managed;
    private final java.util.Set<Integer> windowingRejected = new java.util.HashSet<>();
    private boolean displayWindowing;
    private String windowWarning;
    private final java.util.Set<Integer> minimized = new java.util.HashSet<>();
    private final java.util.Map<Integer, Rect> restoreBounds = new java.util.HashMap<>();

    DesktopControl(Context context, int displayId, int width, int height) throws Exception {
        this(context, displayId, width, height, null);
    }

    DesktopControl(Context context, int displayId, int width, int height, DesktopAppWindows managed) throws Exception {
        this.managed = managed;
        if (displayId <= 0) throw new IllegalArgumentException("Desktop requires an independent display");
        this.context = context;
        this.displayId = displayId;
        this.width = width;
        this.height = height;
        api = Class.forName("android.app.IActivityTaskManager");
        service = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null);
        if (managed != null) return;
        try {
            Object binder = Class.forName("android.os.ServiceManager").getMethod("getService", String.class)
                    .invoke(null, "window");
            Object window = Class.forName("android.view.IWindowManager$Stub")
                    .getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
            Class<?> windowApi = Class.forName("android.view.IWindowManager");
            // This display is created and destroyed by DexLink. Never change
            // the default display or any global developer/settings flags.
            windowApi.getMethod("setWindowingMode", int.class, int.class).invoke(window, displayId, 5);
            displayWindowing = (Integer) windowApi.getMethod("getWindowingMode", int.class).invoke(window, displayId) == 5;
        } catch (Exception error) {
            System.err.println("DexLink independent display windowing unavailable: " + error);
        }
    }

    void home() throws Exception {
        if (managed != null) { managed.home(); launch(HOME, false); return; }
        for (ActivityManager.RunningTaskInfo task : runningTasks()) {
            if (taskDisplay(task) == displayId && !ownHome(task)) {
                transaction(task, null, true);
                minimized.add(task.id);
            }
        }
        launch(HOME, false);
    }

    JSONObject handle(JSONObject request) {
        JSONObject result = new JSONObject();
        try {
            String action = request.getString("action");
            if (managed != null && !action.equals("apps") && !action.equals("icons") && !action.equals("state") && !action.equals("launch")) {
                managed.handle(request);
            } else switch (action) {
                case "state": break;
                case "apps": result.put("apps", apps()).put("iconBatches", true); break;
                case "icons": result.put("icons", icons(request.getJSONArray("components"))); break;
                case "home": home(); break;
                case "launch": {
                    String component = request.getString("component");
                    ComponentName target = ComponentName.unflattenFromString(component);
                    if (target == null || !isLaunchable(target)) throw new IllegalArgumentException("应用不在可启动列表");
                    if (managed != null) managed.launch(component, request.optString("layout", AppDisplayProfile.TABLET));
                    else launch(component, freeform());
                    break;
                }
                case "bounds": {
                    int id = request.getInt("taskId");
                    ActivityManager.RunningTaskInfo task = requireTask(id);
                    int w = Math.max(Math.min(320, width), Math.min(width, request.getInt("width")));
                    int h = Math.max(Math.min(240, height), Math.min(height, request.getInt("height")));
                    int x = Math.max(0, Math.min(width - w, request.getInt("x")));
                    int y = Math.max(0, Math.min(height - h, request.getInt("y")));
                    transaction(task, new Rect(x, y, x + w, y + h), false);
                    restoreBounds.put(id, new Rect(x, y, x + w, y + h));
                    minimized.remove(id);
                    break;
                }
                case "focus": case "close": case "maximize": case "restore": case "minimize":
                case "left": case "right": {
                    int id = request.getInt("taskId");
                    requireTask(id);
                    if (action.equals("minimize")) {
                        transaction(requireTask(id), null, true);
                        minimized.add(id);
                    } else if (action.equals("close")) {
                        if (!Boolean.TRUE.equals(api.getMethod("removeTask", int.class).invoke(service, id))) {
                            throw new IllegalStateException("系统拒绝关闭任务");
                        }
                        minimized.remove(id);
                        windowingRejected.remove(id);
                        restoreBounds.remove(id);
                    } else {
                        transaction(requireTask(id), null, false);
                        minimized.remove(id);
                        ActivityOptions options = ActivityOptions.makeBasic().setLaunchDisplayId(displayId);
                        if (!action.equals("focus")) {
                            if (action.equals("restore") && !freeform()) throw new IllegalStateException("此系统不支持自由窗口");
                            options.getClass().getMethod("setLaunchWindowingMode", int.class).invoke(options, 5);
                        }
                        int status = (Integer) api.getMethod("startActivityFromRecents", int.class, Bundle.class)
                                .invoke(service, id, options.toBundle());
                        if (status < 0) throw new IllegalStateException("系统拒绝激活任务: " + status);
                        if (!action.equals("focus")) {
                            if (!action.equals("restore") && !restoreBounds.containsKey(id)) {
                                Rect current = (Rect) api.getMethod("getTaskBounds", int.class).invoke(service, id);
                                if (current != null && !current.isEmpty()) restoreBounds.put(id, new Rect(current));
                            }
                            Rect size = action.equals("maximize") ? new Rect(0, 0, width, height)
                                    : action.equals("left") ? new Rect(0, 0, width / 2, height)
                                    : action.equals("right") ? new Rect(width / 2, 0, width, height)
                                    : restoreBounds.containsKey(id) ? new Rect(restoreBounds.get(id)) : bounds();
                            transaction(requireTask(id), size, false);
                        }
                    }
                    break;
                }
                default: throw new IllegalArgumentException("未知桌面操作");
            }
            result.put("ok", true);
            if (windowWarning != null) {
                result.put("warning", windowWarning);
                windowWarning = null;
            }
        } catch (Exception error) {
            Throwable cause = error.getCause() == null ? error : error.getCause();
            try { result.put("ok", false).put("error", cause.toString()); } catch (Exception ignored) { }
        }
        try {
            result.put("tasks", tasks()).put("freeform", freeform()).put("displayId", displayId);
        } catch (Exception error) {
            try { result.put("ok", false).put("error", "无法读取桌面任务: " + error); } catch (Exception ignored) { }
        }
        return result;
    }

    private boolean freeform() {
        return managed != null || displayWindowing
                || context.getPackageManager().hasSystemFeature("android.software.freeform_window_management");
    }

    private List<ResolveInfo> launchables() {
        return context.getPackageManager().queryIntentActivities(
                new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0);
    }

    private boolean isLaunchable(ComponentName target) {
        for (ResolveInfo item : launchables()) {
            if (target.getPackageName().equals(item.activityInfo.packageName)
                    && target.getClassName().equals(item.activityInfo.name)) return true;
        }
        return false;
    }

    private JSONArray apps() throws Exception {
        ArrayList<ResolveInfo> entries = new ArrayList<>(launchables());
        entries.sort(new ResolveInfo.DisplayNameComparator(context.getPackageManager()));
        JSONArray result = new JSONArray();
        int iconBytes = 0;
        for (ResolveInfo item : entries) {
            if (result.length() >= 512) break;
            JSONObject app = new JSONObject().put("component", new ComponentName(item.activityInfo.packageName,
                    item.activityInfo.name).flattenToString()).put("label", item.loadLabel(context.getPackageManager()));
            String icon = icon(item);
            // Remaining icons are available in bounded batches, never omitted
            // just because a detailed icon exceeds an arbitrary 4 KiB cutoff.
            if (icon != null && iconBytes + icon.length() < 650_000) {
                app.put("icon", icon);
                iconBytes += icon.length();
            }
            result.put(app);
        }
        return result;
    }

    private JSONArray icons(JSONArray components) throws Exception {
        if (components.length() > 16) throw new IllegalArgumentException("每批最多读取16个图标");
        java.util.Map<String, ResolveInfo> catalog = new java.util.HashMap<>();
        for (ResolveInfo item : launchables()) catalog.put(new ComponentName(item.activityInfo.packageName,
                item.activityInfo.name).flattenToString(), item);
        JSONArray result = new JSONArray();
        for (int i = 0; i < components.length(); i++) {
            String component = components.getString(i);
            ResolveInfo item = catalog.get(component);
            if (item == null) continue;
            JSONObject row = new JSONObject().put("component", component);
            String encoded = icon(item);
            if (encoded != null) row.put("icon", encoded);
            result.put(row);
        }
        return result;
    }

    private String icon(ResolveInfo item) {
        android.content.pm.PackageManager pm = context.getPackageManager();
        for (int attempt = 0; attempt < 3; attempt++) {
            android.graphics.Bitmap bitmap = null;
            try {
                android.graphics.drawable.Drawable drawable = attempt == 0 ? item.loadIcon(pm)
                        : attempt == 1 ? pm.getApplicationIcon(item.activityInfo.applicationInfo)
                        : pm.getResourcesForApplication(item.activityInfo.applicationInfo)
                            .getDrawableForDensity(item.activityInfo.getIconResource(), 320, null);
                if (drawable == null) continue;
                bitmap = android.graphics.Bitmap.createBitmap(64, 64, android.graphics.Bitmap.Config.ARGB_8888);
                drawable.setBounds(0, 0, 64, 64);
                drawable.draw(new android.graphics.Canvas(bitmap));
                java.io.ByteArrayOutputStream png = new java.io.ByteArrayOutputStream();
                if (!bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, png)) continue;
                if (png.size() > 32_768) continue;
                return android.util.Base64.encodeToString(png.toByteArray(), android.util.Base64.NO_WRAP);
            } catch (Exception ignored) { /* Try the application's resource next. */ }
            finally { if (bitmap != null) bitmap.recycle(); }
        }
        return null;
    }

    @SuppressWarnings("unchecked")
    private List<ActivityManager.RunningTaskInfo> runningTasks() throws Exception {
        try {
            return (List<ActivityManager.RunningTaskInfo>) api.getMethod("getTasks", int.class,
                    boolean.class, boolean.class, int.class).invoke(service, 100, false, false, displayId);
        } catch (NoSuchMethodException older) {
            try {
                return (List<ActivityManager.RunningTaskInfo>) api.getMethod("getTasks", int.class,
                        boolean.class, boolean.class).invoke(service, 100, false, false);
            } catch (NoSuchMethodException android10) {
                return (List<ActivityManager.RunningTaskInfo>) api.getMethod("getTasks", int.class,
                        boolean.class).invoke(service, 100, false);
            }
        }
    }

    private int taskDisplay(ActivityManager.RunningTaskInfo task) throws Exception {
        return task.getClass().getField("displayId").getInt(task);
    }

    private int windowMode(ActivityManager.RunningTaskInfo task) throws Exception {
        Object configuration = task.getClass().getField("configuration").get(task);
        Object window = configuration.getClass().getField("windowConfiguration").get(configuration);
        return (Integer) window.getClass().getMethod("getWindowingMode").invoke(window);
    }

    private boolean ownHome(ActivityManager.RunningTaskInfo task) {
        return task.baseActivity != null && task.baseActivity.getClassName().equals("io.dexlink.dex_phone.DesktopActivity");
    }

    private ActivityManager.RunningTaskInfo requireTask(int id) throws Exception {
        for (ActivityManager.RunningTaskInfo task : runningTasks()) {
            if (task.id == id && taskDisplay(task) == displayId && !ownHome(task)) return task;
        }
        throw new IllegalArgumentException("任务不属于当前桌面或已经关闭");
    }

    private JSONArray tasks() throws Exception {
        if (managed != null) return managed.tasks();
        JSONArray result = new JSONArray();
        java.util.Set<Integer> liveTasks = new java.util.HashSet<>();
        for (ActivityManager.RunningTaskInfo task : runningTasks()) {
            if (taskDisplay(task) != displayId || ownHome(task) || task.baseActivity == null) continue;
            liveTasks.add(task.id);
            String label = task.baseActivity.getPackageName();
            try { label = context.getPackageManager().getActivityInfo(task.baseActivity, 0)
                    .loadLabel(context.getPackageManager()).toString(); } catch (Exception ignored) { }
            boolean focused = false;
            try { focused = task.getClass().getField("isFocused").getBoolean(task); } catch (Exception ignored) { }
            result.put(new JSONObject().put("id", task.id).put("label", label)
                    .put("component", task.baseActivity.flattenToString()).put("focused", focused)
                    .put("windowingMode", windowMode(task)).put("windowingRejected", windowingRejected.contains(task.id))
                    .put("minimized", minimized.contains(task.id))
                    .put("bounds", api.getMethod("getTaskBounds", int.class).invoke(service, task.id).toString()));
        }
        windowingRejected.retainAll(liveTasks);
        minimized.retainAll(liveTasks);
        restoreBounds.keySet().retainAll(liveTasks);
        return result;
    }

    private Rect bounds() {
        int offset = (cascade++ % 5) * Math.max(12, width / 60);
        return new Rect(width / 8 + offset, height / 10 + offset,
                width * 7 / 8 + offset, height * 8 / 10 + offset);
    }

    private void changeWindow(int id, int mode) throws Exception {
        for (ActivityManager.RunningTaskInfo task : runningTasks()) {
            if (task.id != id || taskDisplay(task) != displayId) continue;
            if (windowMode(task) == mode) {
                if (mode == 5) windowingRejected.remove(id);
                return;
            }
            try {
                Class<?> transactionClass = Class.forName("android.window.WindowContainerTransaction");
                Class<?> tokenClass = Class.forName("android.window.WindowContainerToken");
                Object transaction = transactionClass.getConstructor().newInstance();
                Object token = task.getClass().getField("token").get(task);
                transactionClass.getMethod("setWindowingMode", tokenClass, int.class).invoke(transaction, token, mode);
                if (mode == 5) transactionClass.getMethod("setBounds", tokenClass, Rect.class).invoke(transaction, token, bounds());
                Object organizer = api.getMethod("getWindowOrganizerController").invoke(service);
                Class.forName("android.window.IWindowOrganizerController")
                        .getMethod("applyTransaction", transactionClass).invoke(organizer, transaction);
                for (ActivityManager.RunningTaskInfo updated : runningTasks()) {
                    if (updated.id == id && windowMode(updated) == mode) {
                        if (mode == 5) windowingRejected.remove(id);
                        return;
                    }
                }
                throw new IllegalStateException("系统未应用窗口模式");
            } catch (Exception error) {
                if (mode == 5) {
                    windowingRejected.add(id);
                    System.err.println("DexLink task windowing rejected: task=" + id
                            + " component=" + task.baseActivity + " error=" + error);
                }
                throw new IllegalStateException("系统拒绝自由窗口，应用仍可通过任务标签切换: " + error, error);
            }
        }
        throw new IllegalStateException("任务已结束");
    }

    private void transaction(ActivityManager.RunningTaskInfo task, Rect bounds, boolean hidden) throws Exception {
        Class<?> type = Class.forName("android.window.WindowContainerTransaction");
        Class<?> tokenType = Class.forName("android.window.WindowContainerToken");
        Object tx = type.getConstructor().newInstance();
        Object token = task.getClass().getField("token").get(task);
        type.getMethod("setHidden", tokenType, boolean.class).invoke(tx, token, hidden);
        if (bounds != null) {
            type.getMethod("setWindowingMode", tokenType, int.class).invoke(tx, token, 5);
            type.getMethod("setBounds", tokenType, Rect.class).invoke(tx, token, bounds);
        }
        Object organizer = api.getMethod("getWindowOrganizerController").invoke(service);
        Class.forName("android.window.IWindowOrganizerController").getMethod("applyTransaction", type).invoke(organizer, tx);
    }

    private void launch(String component, boolean windowed) throws Exception {
        boolean home = HOME.equals(component);
        if (!home) {
            String packageName = ComponentName.unflattenFromString(component).getPackageName();
            for (ActivityManager.RunningTaskInfo task : runningTasks()) {
                if (taskDisplay(task) == displayId && task.baseActivity != null
                        && task.baseActivity.getPackageName().equals(packageName)) {
                    transaction(task, null, false);
                    minimized.remove(task.id);
                    ActivityOptions options = ActivityOptions.makeBasic().setLaunchDisplayId(displayId);
                    api.getMethod("startActivityFromRecents", int.class, Bundle.class).invoke(service, task.id, options.toBundle());
                    return;
                }
            }
        }
        ArrayList<String> args = new ArrayList<>();
        java.util.Collections.addAll(args, "am", "start", "--display", Integer.toString(displayId),
                "--windowingMode", windowed ? "5" : "1", "-f", home ? "0x10000000" : "0x18000000", "-n", component);
        ShellControl.runCommand(args.toArray(new String[0]));
        // Bounds and window decorations are managed by Android, not simulated
        // Flutter rectangles. Unsupported OEM policies are reported to the PC.
        if (windowed) {
            for (ActivityManager.RunningTaskInfo task : runningTasks()) {
                if (taskDisplay(task) == displayId && task.baseActivity != null
                        && task.baseActivity.getPackageName().equals(ComponentName.unflattenFromString(component).getPackageName())) {
                    try { changeWindow(task.id, 5); }
                    catch (Exception error) {
                        windowWarning = "应用已打开，但系统拒绝窗口化，当前使用全屏任务标签切换";
                    }
                    if (!windowingRejected.contains(task.id)) transaction(task, bounds(), false);
                    minimized.remove(task.id);
                    break;
                }
            }
        }
    }
}
