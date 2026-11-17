package io.dexlink.dex_phone.capture;

import java.io.DataOutputStream;
import java.io.IOException;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.function.LongSupplier;
import java.util.concurrent.locks.LockSupport;

/** Bounds unsent access units without retaining MediaCodec output slots. */
public final class VideoSender implements AutoCloseable {
    static final long CONFIG = 1L << 62, KEY = 1L << 61;
    static final long MAX_AGE_NS = 100_000_000L;
    static final int MAX_FRAMES = 64, MAX_BYTES = 8 * 1024 * 1024;

    public interface Sent { void accept(int bytes, long nanos, boolean config, long pts); }

    private static final class Frame {
        final long header, at;
        final byte[] bytes, config;
        Frame(long header, byte[] bytes, byte[] config, long at) {
            this.header = header; this.bytes = bytes; this.config = config; this.at = at;
        }
    }

    static final class Stats {
        final int queued, bytes;
        final long dropped;
        final double oldestMs, writingMs, peakQueueMs, peakWritingMs;
        double tcpWritingMs, tcpPeakWritingMs;
        Stats(int queued, int bytes, long dropped, double oldestMs, double writingMs,
                double peakQueueMs, double peakWritingMs) {
            this.queued = queued; this.bytes = bytes; this.dropped = dropped;
            this.oldestMs = oldestMs; this.writingMs = writingMs;
            this.peakQueueMs = peakQueueMs; this.peakWritingMs = peakWritingMs;
        }
    }

    private final DataOutputStream output;
    private final Runnable requestSync;
    private final Sent sent;
    private final LongSupplier clock;
    private final VideoPacer pacer = new VideoPacer();
    private final ArrayDeque<Frame> queue = new ArrayDeque<>();
    private final Thread worker;
    private byte[] config;
    private int bytes;
    private long dropped, lastSync = Long.MIN_VALUE, writingAt = -1;
    private int failedRecoveryKeys;
    private long peakQueueNs, peakWritingNs;
    private boolean waitingKey = true, closed;
    private IOException failure;
    private volatile RealtimeVideoTransport realtime;
    private VideoSender tcpFallback;
    private volatile boolean tcpSelected = true;
    private int bitrate;

    public VideoSender(DataOutputStream output, Runnable requestSync, Sent sent) {
        this(output, requestSync, sent, System::nanoTime);
    }

    VideoSender(DataOutputStream output, Runnable requestSync, Sent sent, LongSupplier clock) {
        this.output = output; this.requestSync = requestSync; this.sent = sent; this.clock = clock;
        worker = new Thread(this::writeLoop, "dexlink-video-send");
        worker.setDaemon(true);
        worker.start();
    }

    // Ownership of data transfers to this sender; callers must not reuse it.
    public void offer(long header, byte[] data) throws IOException {
        offer(header, data, clock.getAsLong());
    }

    private void offer(long header, byte[] data, long capturedAt) throws IOException {
        boolean sync;
        synchronized (this) {
            checkFailure();
            if (closed) return;
            long now = clock.getAsLong();
            pressure(now);
            if ((header & CONFIG) != 0) {
                if (!Arrays.equals(config, data)) {
                    discard();
                    config = data;
                }
            } else {
                boolean key = (header & KEY) != 0;
                if ((!queue.isEmpty() && now - queue.peekFirst().at >= MAX_AGE_NS)
                        || queue.size() >= MAX_FRAMES || bytes + (long) data.length > MAX_BYTES) {
                    retainFreshKey(now);
                    if (queue.size() >= MAX_FRAMES || bytes + (long) data.length > MAX_BYTES) discard();
                }
                if (data.length > MAX_BYTES || (waitingKey && !key)) {
                    dropped++;
                } else {
                    if (key) waitingKey = false;
                    queue.addLast(new Frame(header, data, key ? config : null, capturedAt));
                    bytes += data.length;
                    notifyAll();
                }
            }
            sync = needsSync(now);
        }
        if (sync) requestSync.run();
    }

    public synchronized void checkFailure() throws IOException {
        if (failure != null) throw failure;
        if (tcpFallback != null) tcpFallback.checkFailure();
    }

    // Reconfiguration/minimization invalidates queued pixels, but not an
    // already-started wire packet. The next accepted picture must be an IDR.
    synchronized void reset() {
        discard();
        if (tcpFallback != null) tcpFallback.reset();
    }

    public synchronized void setBitrate(int bitrate) {
        this.bitrate = bitrate;
        pacer.setBitrate(bitrate);
        if (realtime != null) realtime.setBitrate(bitrate);
        if (tcpFallback != null) tcpFallback.setBitrate(bitrate);
    }
    synchronized void setRealtime(RealtimeVideoTransport value) {
        if (realtime == value) return;
        if (value == null || realtime != null || config != null || writingAt >= 0 || closed)
            throw new IllegalStateException("Configure realtime transport before offering video");
        // Only this child owns the TCP stream. A blocked TCP packet must never
        // hold the realtime worker; each path retains its own bounded queue.
        tcpFallback = new VideoSender(output, this::requestTcpSync,
                (size, nanos, config, pts) -> {
                    if (tcpSelected) sent.accept(size, nanos, config, pts);
                }, clock);
        tcpFallback.setBitrate(bitrate);
        value.setBitrate(bitrate);
        realtime = value;
    }

    private void requestTcpSync() {
        synchronized (this) {
            long now = clock.getAsLong();
            if (closed || !tcpSelected || (lastSync != Long.MIN_VALUE && now - lastSync < 300_000_000L)) return;
            lastSync = now;
        }
        requestSync.run();
    }
    RealtimeVideoTransport.NetworkFeedback networkFeedback() { return realtime == null ? null : realtime.feedback(); }

    synchronized Stats stats() { return stats(false); }

    synchronized Stats stats(boolean resetPeaks) {
        long now = clock.getAsLong();
        pressure(now);
        Stats tcp = tcpFallback == null ? null : tcpFallback.stats(resetPeaks);
        boolean activeTcp = tcp != null && tcpSelected;
        Stats result = new Stats(queue.size() + (tcp == null ? 0 : tcp.queued),
                bytes + (tcp == null ? 0 : tcp.bytes), dropped + (tcp == null ? 0 : tcp.dropped),
                Math.max(queue.isEmpty() ? 0 : Math.max(0, now - queue.peekFirst().at) / 1_000_000.0,
                        activeTcp ? tcp.oldestMs : 0),
                Math.max(writingAt < 0 ? 0 : Math.max(0, now - writingAt) / 1_000_000.0,
                        activeTcp ? tcp.writingMs : 0),
                Math.max(peakQueueNs / 1_000_000.0, activeTcp ? tcp.peakQueueMs : 0),
                Math.max(peakWritingNs / 1_000_000.0, activeTcp ? tcp.peakWritingMs : 0));
        if (tcp != null) {
            result.tcpWritingMs = tcp.writingMs;
            result.tcpPeakWritingMs = tcp.peakWritingMs;
        }
        if (resetPeaks) peakQueueNs = peakWritingNs = 0;
        return result;
    }

    private void pressure(long now) {
        if (!queue.isEmpty()) peakQueueNs = Math.max(peakQueueNs, now - queue.peekFirst().at);
        if (writingAt >= 0) peakWritingNs = Math.max(peakWritingNs, now - writingAt);
    }

    // A fresh queued IDR already breaks the old dependency chain. Keep its
    // complete tail instead of throwing it away and waiting for another IDR.
    private void retainFreshKey(long now) {
        Frame fresh = null;
        for (java.util.Iterator<Frame> it = queue.descendingIterator(); it.hasNext();) {
            Frame frame = it.next();
            if ((frame.header & KEY) != 0 && now - frame.at < MAX_AGE_NS) { fresh = frame; break; }
        }
        if (fresh == null) { discard(); return; }
        while (queue.peekFirst() != fresh) {
            bytes -= queue.removeFirst().bytes.length;
            dropped++;
        }
        waitingKey = false;
    }

    private void discard() {
        dropped += queue.size();
        queue.clear();
        bytes = 0;
        waitingKey = true;
    }

    private boolean needsSync(long now) {
        // Congestion alone does not invalidate references. Requesting large
        // IDRs into a blocked socket amplifies the burst, and those pictures
        // expire before they can be sent. Recover once the in-flight write
        // finishes and a dependency chain actually needs replacing.
        long retryNs = failedRecoveryKeys == 0 ? 300_000_000L
                : Math.min(3, failedRecoveryKeys) * 100_000_000L;
        if (!waitingKey || writingAt >= 0 || (tcpSelected && tcpFallback != null && tcpFallback.isWriting())
                || (lastSync != Long.MIN_VALUE && now - lastSync < retryNs)) return false;
        lastSync = now;
        return true;
    }

    private synchronized boolean isWriting() { return writingAt >= 0; }

    private void writeLoop() {
        try {
            while (true) {
                Frame frame;
                boolean sync;
                synchronized (this) {
                    while (!closed && queue.isEmpty()) wait();
                    if (closed) return;
                    long now = clock.getAsLong();
                    pressure(now);
                    if (now - queue.peekFirst().at >= MAX_AGE_NS) retainFreshKey(now);
                    sync = needsSync(now);
                    frame = queue.pollFirst();
                    if (frame != null) {
                        bytes -= frame.bytes.length;
                        writingAt = now;
                    }
                }
                if (sync) requestSync.run();
                if (frame == null) continue;
                // Config travels with the IDR that references it. Never send a
                // predictive tail after discarding one of its reference frames.
                long started = clock.getAsLong();
                int transported = realtime == null ? 0 : realtime.send(frame.header, frame.bytes, frame.config);
                if (transported != 0 && tcpSelected) {
                    // An attempted UDP chain owns recovery too. Even a failed
                    // first IDR must be able to retry while old TCP is blocked.
                    tcpSelected = false;
                    tcpFallback.reset();
                }
                if (transported > 0) {
                    sent.accept(frame.bytes.length, clock.getAsLong() - started, false, frame.header & ~(CONFIG | KEY));
                } else if (transported == 0) {
                    if (tcpFallback != null) {
                        tcpSelected = true;
                        if (frame.config != null) tcpFallback.offer(CONFIG, frame.config);
                        tcpFallback.offer(frame.header, frame.bytes, frame.at);
                    } else {
                        if (frame.config != null) write(CONFIG, frame.config);
                        write(frame.header, frame.bytes);
                    }
                } else {
                    synchronized (this) {
                        if ((frame.header & KEY) != 0) failedRecoveryKeys = Math.min(3, failedRecoveryKeys + 1);
                        dropped++;
                        discard();
                    }
                }
                synchronized (this) {
                    if (transported >= 0 && (frame.header & KEY) != 0) {
                        // A completed independent frame ends the old recovery
                        // attempt. Its cooldown must not delay a new failure.
                        failedRecoveryKeys = 0;
                        lastSync = Long.MIN_VALUE;
                    }
                    long now = clock.getAsLong();
                    pressure(now);
                    writingAt = -1;
                    sync = needsSync(now);
                }
                if (sync) requestSync.run();
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        } catch (Exception error) {
            synchronized (this) {
                if (!closed) failure = error instanceof IOException
                        ? (IOException) error : new IOException("Video sender failed", error);
                discard();
                writingAt = -1;
                notifyAll();
            }
        }
    }

    private void write(long header, byte[] data) throws IOException {
        long start = clock.getAsLong();
        output.writeLong(header);
        output.writeInt(data.length);
        long waited = 0;
        for (int offset = 0; offset < data.length;) {
            int count = waited >= VideoPacer.MAX_WAIT_NS ? data.length - offset
                    : Math.min(VideoPacer.CHUNK_BYTES, data.length - offset);
            long delay = pacer.reserve(count, clock.getAsLong(), VideoPacer.MAX_WAIT_NS - waited);
            if (delay > 0) {
                long until = System.nanoTime() + delay;
                while (!Thread.currentThread().isInterrupted() && System.nanoTime() < until) {
                    LockSupport.parkNanos(Math.min(1_000_000L, until - System.nanoTime()));
                }
                waited += delay;
            }
            output.write(data, offset, count);
            output.flush();
            offset += count;
        }
        sent.accept(data.length, clock.getAsLong() - start,
                (header & CONFIG) != 0, header & ~(CONFIG | KEY));
    }

    @Override public synchronized void close() {
        closed = true;
        discard();
        if (tcpFallback != null) tcpFallback.close();
        notifyAll();
    }

    // The owner closes the socket first, which cancels a blocked write.
    public boolean awaitTermination() {
        try { worker.join(1000); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        return !worker.isAlive() & (tcpFallback == null || tcpFallback.awaitTermination());
    }
}
