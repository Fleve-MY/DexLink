package io.dexlink.dex_phone.capture;

import java.io.DataInputStream;
import java.net.ServerSocket;
import java.net.Socket;

/** The shell owns streaming sockets so freezing the phone UI cannot block them. */
final class DirectTransport implements AutoCloseable {
    private final ServerSocket listener = new ServerSocket(0, 4);
    private final String token;
    Socket video;
    Socket control;
    Socket audio;
    RealtimeVideoTransport realtime;

    DirectTransport(String token) throws Exception { this.token = token; }
    int port() { return listener.getLocalPort(); }

    void enableRealtime(Runnable sync) {
        try { realtime = new RealtimeVideoTransport(video.getLocalPort(), token, video.getInetAddress(), sync); }
        catch (Exception unavailable) { System.err.println("DexLink realtime transport unavailable: " + unavailable); }
    }

    void accept() throws Exception {
        long deadline = android.os.SystemClock.elapsedRealtime() + 30_000;
        try {
            while (video == null || control == null) {
                long remaining = deadline - android.os.SystemClock.elapsedRealtime();
                if (remaining <= 0) throw new java.net.SocketTimeoutException("Direct stream connection timed out");
                listener.setSoTimeout((int) remaining);
                Socket candidate = listener.accept();
                boolean accepted = false;
                try {
                    candidate.setSoTimeout((int) Math.min(remaining, 3000));
                    candidate.setTcpNoDelay(true);
                    DataInputStream input = new DataInputStream(candidate.getInputStream());
                    int size = input.readUnsignedShort();
                    if (size != token.length()) continue;
                    byte[] auth = new byte[size];
                    input.readFully(auth);
                    if (!java.security.MessageDigest.isEqual(auth,
                            token.getBytes(java.nio.charset.StandardCharsets.UTF_8))) continue;
                    int channel = input.readUnsignedByte();
                    if (!((channel == 'V' && video == null)
                            || (channel == 'C' && control == null)
                            || (channel == 'A' && audio == null))) continue;
                    // Keep unsent video in the frame-aware sender, where it
                    // can expire, rather than seconds of opaque TCP buffering.
                    if (channel == 'V') candidate.setSendBufferSize(64 * 1024);
                    candidate.setSoTimeout(0);
                    if (channel == 'V') video = candidate;
                    else if (channel == 'C') control = candidate;
                    else audio = candidate;
                    accepted = true;
                } catch (java.io.IOException invalidClient) {
                    // A partial or unauthenticated client cannot claim a channel.
                } finally {
                    if (!accepted) candidate.close();
                }
            }
        } finally {
            listener.close();
        }
    }

    public void close() {
        if (realtime != null) realtime.close();
        try { listener.close(); } catch (Exception ignored) { }
        try { if (video != null) video.close(); } catch (Exception ignored) { }
        try { if (control != null) control.close(); } catch (Exception ignored) { }
        try { if (audio != null) audio.close(); } catch (Exception ignored) { }
    }
}
