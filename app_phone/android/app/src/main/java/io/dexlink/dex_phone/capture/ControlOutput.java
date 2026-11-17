package io.dexlink.dex_phone.capture;

import java.io.DataOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ArrayBlockingQueue;
import org.json.JSONObject;

/** Serializes all control replies. Diagnostics never block the video thread. */
final class ControlOutput implements AutoCloseable {
    private final DataOutputStream output;
    private final ArrayBlockingQueue<byte[]> telemetry = new ArrayBlockingQueue<>(1);
    private final Thread worker;
    private volatile boolean closed;

    ControlOutput(OutputStream sink, boolean reportTelemetry) {
        output = new DataOutputStream(sink);
        worker = reportTelemetry ? new Thread(() -> {
            try {
                while (!closed) jsonBytes(24, telemetry.take());
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            } catch (IOException error) {
                try { output.close(); } catch (IOException ignored) { }
            }
        }, "dexlink-telemetry") : null;
        if (worker != null) { worker.setDaemon(true); worker.start(); }
    }

    synchronized void clipboard(String text) throws IOException {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        output.writeByte(0); output.writeInt(bytes.length); output.write(bytes); output.flush();
    }

    synchronized void ack(long sequence) throws IOException {
        output.writeByte(1); output.writeLong(sequence); output.flush();
    }

    synchronized void panel(boolean on, boolean success) throws IOException {
        output.writeByte(20); output.writeBoolean(on); output.writeBoolean(success); output.flush();
    }

    void json(int type, JSONObject data) throws IOException {
        jsonBytes(type, data.toString().getBytes(StandardCharsets.UTF_8));
    }

    private synchronized void jsonBytes(int type, byte[] bytes) throws IOException {
        output.writeByte(type); output.writeInt(bytes.length); output.write(bytes); output.flush();
    }

    void telemetry(JSONObject data) {
        if (worker == null || closed) return;
        byte[] bytes = data.toString().getBytes(StandardCharsets.UTF_8);
        // At most one pending snapshot; stale diagnostics are replaceable.
        if (!telemetry.offer(bytes)) { telemetry.poll(); telemetry.offer(bytes); }
    }

    @Override public void close() {
        closed = true;
        if (worker != null) worker.interrupt();
        telemetry.clear();
    }
}
