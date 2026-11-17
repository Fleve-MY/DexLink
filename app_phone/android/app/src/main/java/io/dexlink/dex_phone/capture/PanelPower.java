package io.dexlink.dex_phone.capture;

import android.content.Context;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import java.lang.reflect.Method;

/** Controls physical panels without putting Android or the capture display to sleep. */
@android.annotation.SuppressLint({"PrivateApi", "BlockedPrivateApi", "SoonBlockedPrivateApi"})
final class PanelPower {
    private final IBinder[] panels;
    private final Method setMode;
    private final PowerManager.WakeLock wakeLock;
    private boolean dark;
    private boolean closed;
    private boolean wasInteractive = true;
    private boolean wasLocked;
    private boolean awaitRemoteInteraction;

    PanelPower(Context context) throws Exception {
        Class<?> surface = Class.forName("android.view.SurfaceControl");
        Class<?> tokens = surface;
        if (Build.VERSION.SDK_INT >= 34) {
            // Recent Android moved physical display discovery into the system
            // server library. Resolve that platform API only in shell app_process.
            Class<?> factory = Class.forName("com.android.internal.os.ClassLoaderFactory");
            Method create = factory.getDeclaredMethod("createClassLoader", String.class,
                    String.class, String.class, ClassLoader.class, int.class, boolean.class, String.class);
            ClassLoader loader = (ClassLoader) create.invoke(null,
                    android.system.Os.getenv("SYSTEMSERVERCLASSPATH"), null, null,
                    ClassLoader.getSystemClassLoader(), 0, true, null);
            tokens = loader.loadClass("com.android.server.display.DisplayControl");
            Method load = Runtime.class.getDeclaredMethod("loadLibrary0", Class.class, String.class);
            load.setAccessible(true);
            load.invoke(Runtime.getRuntime(), tokens, "android_servers");
        }
        long[] ids = (long[]) tokens.getMethod("getPhysicalDisplayIds").invoke(null);
        if (ids == null || ids.length == 0) throw new IllegalStateException("No physical display");
        panels = new IBinder[ids.length];
        Method token = tokens.getMethod("getPhysicalDisplayToken", long.class);
        for (int i = 0; i < ids.length; i++) {
            panels[i] = (IBinder) token.invoke(null, ids[i]);
            if (panels[i] == null) throw new IllegalStateException("Missing physical display token");
        }
        setMode = surface.getMethod("setDisplayPowerMode", IBinder.class, int.class);
        // Keep Android logically awake so its normal screen timeout does not
        // suspend the mirrored content. The panel itself is switched off below.
        wakeLock = context.getSystemService(PowerManager.class).newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK, "DexLink:Capture");
        wakeLock.setReferenceCounted(false);
    }

    synchronized void setOn(boolean on) throws Exception {
        if (closed) throw new IllegalStateException("Capture session closed");
        if (!on && !wakeLock.isHeld()) wakeLock.acquire(12 * 60 * 60 * 1000L);
        // Mark before invoking: even a partially applied operation must restore
        // all panels on disconnect instead of leaving the phone dark.
        if (!on) dark = true;
        for (IBinder panel : panels) setMode.invoke(null, panel, on ? 2 : 0);
        awaitRemoteInteraction = false;
        if (on) {
            dark = false;
            if (wakeLock.isHeld()) wakeLock.release();
        }
    }

    /** Unlock alone must leave the phone usable. Re-arm on screen transitions,
     * then wait for the next actual remote interaction to turn the panel off. */
    synchronized void screenState(boolean interactive, boolean locked) {
        if (closed) return;
        if (dark && (!interactive || locked || !wasInteractive || wasLocked)) awaitRemoteInteraction = true;
        wasInteractive = interactive;
        wasLocked = locked;
    }

    synchronized void remoteInteraction(boolean interactive, boolean locked) throws Exception {
        screenState(interactive, locked);
        if (!closed && dark && awaitRemoteInteraction && interactive && !locked) {
            setOn(false);
            System.out.println("DexLink panel: reapplied on remote interaction after unlock");
        }
    }

    synchronized void restore() {
        try {
            if (dark) setOn(true);
        } catch (Exception error) {
            System.err.println("DexLink panel restore: " + error);
        } finally {
            if (wakeLock.isHeld()) wakeLock.release();
        }
    }

    synchronized void close() {
        restore();
        closed = true;
    }
}
