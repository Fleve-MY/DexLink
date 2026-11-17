package io.dexlink.dex_phone.capture;

import android.os.IBinder;
import java.lang.reflect.Method;

/** Shell-safe state queries without app-only WindowManagerGlobal initialization. */
@android.annotation.SuppressLint({"PrivateApi", "BlockedPrivateApi", "SoonBlockedPrivateApi"})
final class DeviceState {
    private Object power;
    private Object window;
    private Method interactive;
    private Method locked;
    private boolean warned;

    static final class State {
        final boolean interactive;
        final boolean locked;
        State(boolean interactive, boolean locked) {
            this.interactive = interactive;
            this.locked = locked;
        }
    }

    State read() {
        try {
            if (power == null || window == null) {
                Method service = Class.forName("android.os.ServiceManager")
                        .getMethod("getService", String.class);
                Class<?> powerApi = Class.forName("android.os.IPowerManager");
                Class<?> windowApi = Class.forName("android.view.IWindowManager");
                power = Class.forName("android.os.IPowerManager$Stub")
                        .getMethod("asInterface", IBinder.class).invoke(null, service.invoke(null, "power"));
                window = Class.forName("android.view.IWindowManager$Stub")
                        .getMethod("asInterface", IBinder.class).invoke(null, service.invoke(null, "window"));
                interactive = powerApi.getMethod("isInteractive");
                locked = windowApi.getMethod("isKeyguardLocked");
            }
            return new State((Boolean) interactive.invoke(power), (Boolean) locked.invoke(window));
        } catch (Exception error) {
            if (!warned) System.err.println("DexLink device state unavailable: " + error);
            warned = true;
            // Unknown state must not trigger panel changes or capture recovery.
            // State observation failure must never terminate video encoding.
            return new State(false, true);
        }
    }
}
