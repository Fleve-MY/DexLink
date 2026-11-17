package io.dexlink.dex_phone.capture;

/** Bounded recovery for an idle capture source, independent of Android APIs. */
final class CaptureWatchdog {
    private long lastFrame;
    private long nextAttempt;
    private int attempts;

    CaptureWatchdog(long now) { frame(now); }

    void frame(long now) {
        lastFrame = now;
        nextAttempt = now + 2500;
        attempts = 0;
    }

    boolean recover(long now, boolean screenAvailable) {
        if (!screenAvailable) {
            lastFrame = now;
            attempts = 0;
            nextAttempt = now + 2500;
            return false;
        }
        if (attempts >= 3 || now < nextAttempt || now - lastFrame < 2500) return false;
        attempts++;
        nextAttempt = now + 3000;
        return true;
    }

    boolean exhausted(long now) { return attempts >= 3 && now >= nextAttempt; }
    int attempts() { return attempts; }
}
