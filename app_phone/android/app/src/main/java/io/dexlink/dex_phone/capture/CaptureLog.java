package io.dexlink.dex_phone.capture;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;

/** Direct mode logs must not block on pipes drained by a frozen UI process. */
final class CaptureLog extends OutputStream {
    private final int priority;
    private final ByteArrayOutputStream line = new ByteArrayOutputStream();
    private CaptureLog(int priority) { this.priority = priority; }

    static void install() {
        System.setOut(new PrintStream(new CaptureLog(android.util.Log.INFO), true));
        System.setErr(new PrintStream(new CaptureLog(android.util.Log.ERROR), true));
    }

    @Override public synchronized void write(int value) {
        if (value == '\n' || line.size() >= 4096) {
            if (line.size() > 0) {
                android.util.Log.println(priority, "DexLinkCapture",
                        new String(line.toByteArray(), StandardCharsets.UTF_8));
                line.reset();
            }
        }
        if (value != '\n' && value != '\r') line.write(value);
    }
}
