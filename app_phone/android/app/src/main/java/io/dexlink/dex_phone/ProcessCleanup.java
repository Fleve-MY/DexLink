package io.dexlink.dex_phone;

/** Cleanup for local and Shizuku-backed processes; never wait on a remote proxy. */
public final class ProcessCleanup {
    private ProcessCleanup() {}

    public static boolean isRunning(Process process) {
        try {
            process.exitValue();
            return false;
        } catch (IllegalArgumentException running) {
            // Local Process and Shizuku use different exceptions while alive.
            return true;
        }
    }

    public static void terminate(Process process) {
        if (process == null) return;
        try {
            // Shizuku's exitValue() throws IllegalArgumentException while alive,
            // but Process.waitFor(timeout) expects IllegalThreadStateException.
            // Explicitly terminate the session without that incompatible poll.
            process.destroy();
        } catch (RuntimeException ignored) {
            // The binder or remote process can already be gone during teardown.
        }
    }
}
