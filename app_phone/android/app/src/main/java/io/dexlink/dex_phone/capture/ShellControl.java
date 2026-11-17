package io.dexlink.dex_phone.capture;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Point;
import android.hardware.display.DisplayManager;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

/** Executes DexLink control messages directly under the Shizuku shell identity. */
final class ShellControl {
    private final Context context;
    private final DisplayManager displays;
    private final int displayId;
    private volatile int videoWidth;
    private volatile int videoHeight;
    private final Runnable sync;
    private final PanelPower panelPower;
    private final DeviceState deviceState = new DeviceState();
    private final Object inputManager;
    private final Method inject;
    private final Method setDisplayId;
    private long touchDown;
    private long keyDown;
    private final DesktopControl desktop;
    private final java.util.function.IntUnaryOperator bitrate;

    ShellControl(Context context, DisplayManager displays, int displayId,
                 int width, int height, Runnable sync, PanelPower panelPower,
                 java.util.function.IntUnaryOperator bitrate) throws Exception {
        this(context, displays, displayId, width, height, sync, panelPower, bitrate,
                displayId > 0 ? new DesktopControl(context, displayId, width, height) : null);
    }

    ShellControl(Context context, DisplayManager displays, int displayId,
                 int width, int height, Runnable sync, PanelPower panelPower,
                 java.util.function.IntUnaryOperator bitrate, DesktopControl workspace) throws Exception {
        this.context = context;
        this.displays = displays;
        this.displayId = displayId;
        videoWidth = width;
        videoHeight = height;
        this.sync = sync;
        this.panelPower = panelPower;
        this.bitrate = bitrate;
        desktop = workspace;
        Class<?> input;
        try {
            input = Class.forName("android.hardware.input.InputManagerGlobal");
        } catch (ClassNotFoundException olderAndroid) {
            input = Class.forName("android.hardware.input.InputManager");
        }
        inputManager = input.getMethod("getInstance").invoke(null);
        inject = input.getMethod("injectInputEvent", InputEvent.class, int.class);
        setDisplayId = InputEvent.class.getMethod("setDisplayId", int.class);
    }

    void resizeVideo(int width, int height) { videoWidth = width; videoHeight = height; }

    void read(InputStream source, ControlOutput output) throws Exception {
        DataInputStream input = new DataInputStream(new BufferedInputStream(source, 16 * 1024));
        try {
            while (true) {
                int type = input.readUnsignedByte();
                if (panelPower != null && (type <= 7 || type == 9 || type == 11 || type == 16)) {
                    try {
                        DeviceState.State state = deviceState.read();
                        panelPower.remoteInteraction(state.interactive, state.locked);
                    } catch (Exception error) {
                        System.err.println("DexLink panel reapply: " + error);
                    }
                }
                switch (type) {
                    case 0: {
                        int action = input.readUnsignedByte();
                        int code = input.readInt();
                        int repeat = input.readInt();
                        int meta = input.readInt();
                        key(action, code, repeat, meta);
                        break;
                    }
                    case 1: text(readString(input)); break;
                    case 2: {
                        int action = input.readUnsignedByte();
                        long pointer = input.readLong(); // -1 identifies a real desktop mouse.
                        int x = input.readInt();
                        int y = input.readInt();
                        int width = input.readUnsignedShort();
                        int height = input.readUnsignedShort();
                        int pressure = input.readUnsignedShort();
                        int actionButton = input.readInt();
                        int buttons = input.readInt();
                        if (width == videoWidth && height == videoHeight) {
                            if (pointer == -1) mouse(action, x, y, actionButton, buttons);
                            else touch(action, x, y, pressure == 65535 ? 1f : pressure / 65536f);
                        }
                        break;
                    }
                    case 3: {
                        int x = input.readInt();
                        int y = input.readInt();
                        int width = input.readUnsignedShort();
                        int height = input.readUnsignedShort();
                        float horizontal = input.readShort() / 32768f * 16f;
                        float vertical = input.readShort() / 32768f * 16f;
                        input.readInt();
                        if (width == videoWidth && height == videoHeight) scroll(x, y, horizontal, vertical);
                        break;
                    }
                    case 4: key(input.readUnsignedByte(), KeyEvent.KEYCODE_BACK, 0, 0); break;
                    case 5: panel("expandNotificationsPanel"); break;
                    case 6: panel("expandSettingsPanel"); break;
                    case 7: panel("collapsePanels"); break;
                    case 8: {
                        input.readUnsignedByte();
                        ClipData clip = clipboard().getPrimaryClip();
                        String value = clip != null && clip.getItemCount() > 0
                                ? clip.getItemAt(0).coerceToText(context).toString() : "";
                        output.clipboard(value);
                        break;
                    }
                    case 9: {
                        long sequence = input.readLong();
                        boolean paste = input.readUnsignedByte() != 0;
                        String value = readString(input);
                        clipboard().setPrimaryClip(ClipData.newPlainText("DexLink", value));
                        if (paste) press(KeyEvent.KEYCODE_PASTE);
                        if (sequence != 0) {
                            output.ack(sequence);
                        }
                        break;
                    }
                    case 10: {
                        boolean on = input.readUnsignedByte() != 0;
                        boolean success = false;
                        try {
                            if (panelPower == null) throw new IllegalStateException("Panel control unavailable");
                            panelPower.setOn(on);
                            success = true;
                            sync.run();
                        } catch (Exception error) {
                            if (panelPower != null) panelPower.restore();
                            System.err.println("DexLink panel power: " + error);
                        }
                        output.panel(on, success);
                        break;
                    }
                    case 11: {
                        int rotation = (displays.getDisplay(displayId).getRotation() + 1) % 4;
                        runCommand("wm", "user-rotation", "-d", Integer.toString(displayId), "lock", Integer.toString(rotation));
                        break;
                    }
                    case 16: {
                        byte[] name = new byte[input.readUnsignedByte()];
                        input.readFully(name);
                        startApp(new String(name, StandardCharsets.UTF_8));
                        break;
                    }
                    case 17: sync.run(); break;
                    case 23: {
                        String request = readString(input);
                        org.json.JSONObject response;
                        boolean changed = false;
                        try {
                            if (desktop == null) throw new IllegalStateException("当前不是桌面模式");
                            org.json.JSONObject parsed = new org.json.JSONObject(request);
                            String action = parsed.optString("action");
                            changed = !action.equals("state") && !action.equals("apps");
                            response = desktop.handle(parsed);
                        } catch (Exception error) {
                            response = new org.json.JSONObject().put("ok", false).put("error", error.toString());
                        }
                        output.json(21, response);
                        if (changed) sync.run();
                        break;
                    }
                    case 24: {
                        int requested = input.readInt();
                        org.json.JSONObject result = new org.json.JSONObject().put("requested", requested);
                        try {
                            if (bitrate == null) throw new IllegalStateException("未协商动态码率能力");
                            result.put("bitrate", bitrate.applyAsInt(requested)).put("ok", true);
                        } catch (RuntimeException error) {
                            result.put("ok", false).put("error", error.toString());
                        }
                        output.json(25, result);
                        break;
                    }
                    // No encoder reconfiguration is advertised; don't silently
                    // resize only the display while leaving old stream metadata.
                    default: throw new IllegalArgumentException("Unsupported DexLink control message " + type);
                }
            }
        } catch (EOFException ignored) {
            // Closing the bridge is the normal shutdown signal.
        }
    }

    private void send(InputEvent event) throws Exception {
        setDisplayId.invoke(event, displayId);
        if (!Boolean.TRUE.equals(inject.invoke(inputManager, event, 0))) {
            throw new IllegalStateException("Android rejected input injection");
        }
    }

    private void key(int action, int code, int repeat, int meta) throws Exception {
        if (desktop != null && code == KeyEvent.KEYCODE_HOME) {
            if (action == KeyEvent.ACTION_UP) { desktop.home(); sync.run(); }
            return;
        }
        long now = SystemClock.uptimeMillis();
        if (action == KeyEvent.ACTION_DOWN && repeat == 0) keyDown = now;
        send(new KeyEvent(keyDown, now, action, code, repeat, meta,
                KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD));
        if (action == KeyEvent.ACTION_UP &&
                (code == KeyEvent.KEYCODE_HOME || code == KeyEvent.KEYCODE_APP_SWITCH || code == KeyEvent.KEYCODE_BACK)) {
            sync.run();
        }
    }

    private void press(int code) throws Exception {
        key(KeyEvent.ACTION_DOWN, code, 0, 0);
        key(KeyEvent.ACTION_UP, code, 0, 0);
    }

    private void text(String value) throws Exception {
        KeyEvent[] events = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(value.toCharArray());
        if (events != null) {
            for (KeyEvent event : events) send(event);
        } else {
            clipboard().setPrimaryClip(ClipData.newPlainText("DexLink", value));
            press(KeyEvent.KEYCODE_PASTE);
        }
    }

    // Auto-mirroring fits the rotated physical screen inside a fixed video
    // surface. Undo that fit, including black borders, before injecting input.
    private float[] position(int x, int y) {
        Point size = new Point();
        displays.getDisplay(displayId).getRealSize(size);
        float scale = Math.min((float) videoWidth / size.x, (float) videoHeight / size.y);
        float px = (x - (videoWidth - size.x * scale) / 2f) / scale;
        float py = (y - (videoHeight - size.y * scale) / 2f) / scale;
        return new float[]{Math.max(0, Math.min(size.x - 1, px)), Math.max(0, Math.min(size.y - 1, py))};
    }

    private void touch(int action, int x, int y, float pressure) throws Exception {
        long now = SystemClock.uptimeMillis();
        if (action == MotionEvent.ACTION_DOWN) touchDown = now;
        float[] point = position(x, y);
        MotionEvent event = MotionEvent.obtain(touchDown, now, action, point[0], point[1], pressure,
                1f, 0, 1f, 1f, 0, 0);
        event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        try { send(event); } finally { event.recycle(); }
    }

    private void scroll(int x, int y, float horizontal, float vertical) throws Exception {
        float[] point = position(x, y);
        MotionEvent.PointerProperties props = new MotionEvent.PointerProperties();
        props.id = 0;
        props.toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords();
        coords.x = point[0];
        coords.y = point[1];
        coords.setAxisValue(MotionEvent.AXIS_HSCROLL, horizontal);
        coords.setAxisValue(MotionEvent.AXIS_VSCROLL, vertical);
        long now = SystemClock.uptimeMillis();
        MotionEvent event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1,
                new MotionEvent.PointerProperties[]{props}, new MotionEvent.PointerCoords[]{coords},
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        try { send(event); } finally { event.recycle(); }
    }

    private void mouse(int action, int x, int y, int actionButton, int buttons) throws Exception {
        long now = SystemClock.uptimeMillis();
        if (action == MotionEvent.ACTION_DOWN) touchDown = now;
        float[] point = position(x, y);
        MotionEvent.PointerProperties props = new MotionEvent.PointerProperties();
        props.id = 0;
        props.toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords();
        coords.x = point[0]; coords.y = point[1];
        coords.pressure = buttons == 0 ? 0 : 1;
        MotionEvent event = MotionEvent.obtain(touchDown, now, action, 1,
                new MotionEvent.PointerProperties[]{props}, new MotionEvent.PointerCoords[]{coords},
                0, buttons, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        try {
            send(event);
            // Android context-click handlers receive BUTTON_PRESS/RELEASE as
            // well as DOWN/UP. A right click must never become KEYCODE_BACK.
            if (actionButton != 0 && (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_UP)) {
                event.setAction(action == MotionEvent.ACTION_DOWN ? MotionEvent.ACTION_BUTTON_PRESS : MotionEvent.ACTION_BUTTON_RELEASE);
                MotionEvent.class.getMethod("setActionButton", int.class).invoke(event, actionButton);
                send(event);
            }
        } finally { event.recycle(); }
    }

    private ClipboardManager clipboard() { return context.getSystemService(ClipboardManager.class); }

    // statusbar is a shell-only service, deliberately outside SDK service names.
    @android.annotation.SuppressLint("WrongConstant")
    private void panel(String method) throws Exception {
        Object statusBar = context.getSystemService("statusbar");
        if (method.equals("expandSettingsPanel")) {
            statusBar.getClass().getMethod(method, String.class).invoke(statusBar, (Object) null);
        } else {
            statusBar.getClass().getMethod(method).invoke(statusBar);
        }
    }

    void startHome() throws Exception {
        if (desktop != null) desktop.home();
    }

    private void startApp(String name) throws Exception {
        Intent intent;
        if (name.contains("/")) {
            intent = new Intent(Intent.ACTION_MAIN).setComponent(android.content.ComponentName.unflattenFromString(name));
        } else {
            intent = context.getPackageManager().getLaunchIntentForPackage(name);
        }
        if (intent != null) launch(intent);
    }

    private void launch(Intent intent) throws Exception {
        // app_process has no registered application thread. Use Android's
        // shell activity entry instead of Context.startActivity's caller token.
        ArrayList<String> args = new ArrayList<>();
        java.util.Collections.addAll(args, "am", "start", "--display", Integer.toString(displayId),
                "-f", "0x10000000", "-a", Intent.ACTION_MAIN);
        if (intent.getComponent() != null) {
            args.add("-n");
            args.add(intent.getComponent().flattenToString());
        } else if (intent.getCategories() != null) {
            for (String category : intent.getCategories()) {
                args.add("-c");
                args.add(category);
            }
        }
        runCommand(args.toArray(new String[0]));
    }

    private static String readString(DataInputStream input) throws Exception {
        int length = input.readInt();
        if (length < 0 || length > 1 << 20) throw new IllegalArgumentException("Invalid text length");
        byte[] bytes = new byte[length];
        input.readFully(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }

    static void runCommand(String... args) throws Exception {
        Process process = new ProcessBuilder(args).redirectErrorStream(true).start();
        java.io.ByteArrayOutputStream diagnostic = new java.io.ByteArrayOutputStream();
        try (InputStream output = process.getInputStream()) {
            byte[] bytes = new byte[1024];
            int count;
            while ((count = output.read(bytes)) >= 0) {
                if (diagnostic.size() < 65536) diagnostic.write(bytes, 0, count);
            }
        }
        int code = process.waitFor();
        String message = new String(diagnostic.toByteArray(), StandardCharsets.UTF_8);
        if (code != 0 || message.contains("Error:") || message.contains("Exception")) {
            throw new IllegalStateException("DexLink system action failed: " + message.trim());
        }
    }
}
