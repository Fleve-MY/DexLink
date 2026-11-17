package io.dexlink.dex_phone.capture;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.util.LinkedHashMap;
import java.util.concurrent.locks.LockSupport;

/** Video-only datagrams with selective repair, expiry and reliable TCP fallback. */
final class RealtimeVideoTransport implements AutoCloseable {
    private final DatagramChannel channel;
    private final Selector selector;
    private final DatagramOutput output;
    static final long MAX_SEND_NS = 40_000_000L;
    interface DatagramOutput {
        int send(DatagramChannel channel, byte[] bytes, InetSocketAddress target) throws IOException;
    }
    private final VideoDatagramCodec protocol;
    private final InetAddress allowedAddress;
    private final Runnable requestSync;
    private final LinkedHashMap<Long, Cached> cache = new LinkedHashMap<>();
    private final VideoPacer pacer = new VideoPacer();
    private InetSocketAddress peer;
    private long nonce, lastHello = -1, lastSeen, sequence, cachedBytes, retransmits;
    private long feedbackAt, previousBytes, previousFrames, previousLoss;
    private long lastKeyAt, lastKeySequence = -1;
    private long lastUnavailableAt;
    private long disabledAt;
    private long sendWouldBlock, abortedUnits, repairWouldBlock;
    private boolean awaitingKey = true;
    private double baselineRtt = Double.MAX_VALUE;
    private boolean active, disabled, closed;
    private String fallback = "";
    private NetworkFeedback feedback;

    static final class NetworkFeedback {
        final long at;
        final int goodput, frames;
        final double loss, rttMs, rttGrowthMs, receiverMs;
        NetworkFeedback(long at, int goodput, int frames, double loss, double rtt,
                double growth, double receiver) {
            this.at = at; this.goodput = goodput; this.frames = frames;
            this.loss = loss; rttMs = rtt; rttGrowthMs = growth; receiverMs = receiver;
        }
    }
    private static final class Cached {
        final byte[] wire, retries;
        final long at;
        int repairs;
        volatile int sentFragments;
        Cached(byte[] wire, long at) {
            this.wire = wire; this.at = at;
            retries = new byte[(wire.length + VideoDatagramCodec.PAYLOAD - 1) / VideoDatagramCodec.PAYLOAD];
        }
    }

    RealtimeVideoTransport(int port, String token, InetAddress allowed, Runnable requestSync) throws Exception {
        this(port, token, allowed, requestSync, (channel, bytes, target) -> channel.send(ByteBuffer.wrap(bytes), target));
    }

    RealtimeVideoTransport(int port, String token, InetAddress allowed, Runnable requestSync,
            DatagramOutput output) throws Exception {
        this.protocol = new VideoDatagramCodec(token);
        this.allowedAddress = allowed;
        this.requestSync = requestSync;
        this.output = output;
        DatagramChannel opened = DatagramChannel.open();
        Selector selected = null;
        try {
            selected = Selector.open();
            opened.configureBlocking(false);
            opened.socket().setReceiveBufferSize(64 * 1024);
            opened.socket().setSendBufferSize(32 * 1024);
            opened.socket().bind(new InetSocketAddress(port));
            opened.register(selected, SelectionKey.OP_READ);
        } catch (Exception failure) {
            try { opened.close(); } catch (IOException ignored) { }
            if (selected != null) try { selected.close(); } catch (IOException ignored) { }
            throw failure;
        }
        channel = opened;
        selector = selected;
        Thread reader = new Thread(this::receive, "dexlink-video-repair");
        reader.setDaemon(true);
        reader.start();
    }

    void setBitrate(int bitrate) { pacer.setBitrate(bitrate); }
    synchronized NetworkFeedback feedback() {
        return active && feedback != null && System.nanoTime() - feedback.at < 1_000_000_000L ? feedback : null;
    }
    synchronized void telemetry(org.json.JSONObject data) throws org.json.JSONException {
        data.put("udpActive", active).put("udpRetransmits", retransmits).put("udpFallback", fallback);
        data.put("udpSendWouldBlock", sendWouldBlock).put("udpAbortedUnits", abortedUnits)
                .put("udpRepairWouldBlock", repairWouldBlock);
        NetworkFeedback value = feedback();
        if (value != null) data.put("udpRttMs", value.rttMs).put("udpLoss", value.loss)
                .put("udpGoodput", value.goodput).put("udpReceiverMs", value.receiverMs);
    }

    int send(long header, byte[] bytes, byte[] config) throws IOException {
        final InetSocketAddress target;
        final long id, session;
        final byte[] wire;
        final Cached cached;
        synchronized (this) {
            if (closed || disabled || peer == null) return 0;
            if (!active && (header & VideoSender.KEY) == 0) return 0;
            if (active && awaitingKey && (header & VideoSender.KEY) == 0) return -1;
            int size = 12 + bytes.length + (config == null ? 0 : 12 + config.length);
            if (size > VideoDatagramCodec.MAX_FRAME) { disable("oversized-frame"); requestSync.run(); return 0; }
            active = true;
            ByteBuffer out = ByteBuffer.allocate(size);
            if (config != null) out.putLong(VideoSender.CONFIG).putInt(config.length).put(config);
            out.putLong(header).putInt(bytes.length).put(bytes);
            wire = out.array();
            id = ++sequence; session = nonce; target = peer;
            prune(System.nanoTime());
            while (!cache.isEmpty() && cachedBytes + size > VideoDatagramCodec.MAX_FRAME) removeFirst();
            cached = new Cached(wire, System.nanoTime());
            cache.put(id, cached);
            cachedBytes += size;
        }
        int count = (wire.length + VideoDatagramCodec.PAYLOAD - 1) / VideoDatagramCodec.PAYLOAD;
        final long deadline = System.nanoTime() + MAX_SEND_NS;
        long waited = 0;
        try {
            for (int index = 0; index < count; index++) {
                int offset = index * VideoDatagramCodec.PAYLOAD;
                int length = Math.min(VideoDatagramCodec.PAYLOAD, wire.length - offset);
                long wait = pacer.reserve(length + 48, System.nanoTime(), VideoPacer.MAX_WAIT_NS - waited);
                if (wait > 0) { LockSupport.parkNanos(wait); waited += wait; }
                byte[] packet = protocol.encode(VideoDatagramCodec.DATA, session, id, index, count,
                        wire.length, wire, offset, length);
                boolean written = false;
                while (System.nanoTime() < deadline) {
                    synchronized (this) {
                        if (closed || disabled) return (header & VideoSender.KEY) == 0 ? -1 : 0;
                    }
                    if (sendPacket(packet, target)) { written = true; break; }
                    // A full kernel queue must not hold the video writer for
                    // seconds or block the repair reader's heartbeat replies.
                    LockSupport.parkNanos(250_000L);
                }
                if (!written) {
                    synchronized (this) {
                        awaitingKey = true;
                        abortedUnits++;
                        Cached removed = cache.remove(id);
                        if (removed != null) cachedBytes -= removed.wire.length;
                    }
                    unavailable(id, target);
                    return -1;
                }
                cached.sentFragments = index + 1;
            }
        } catch (IOException failure) {
            synchronized (this) { disable("send-error"); }
            requestSync.run();
            // The next TCP picture must be an IDR; send this one only if it is.
            return (header & VideoSender.KEY) == 0 ? -1 : 0;
        }
        synchronized (this) {
            awaitingKey = false;
            if ((header & VideoSender.KEY) != 0) lastKeyAt = 0;
        }
        return 1;
    }

    private void receive() {
        byte[] buffer = new byte[1201];
        while (true) {
            try {
                selector.select(100);
                selector.selectedKeys().clear();
                ByteBuffer input = ByteBuffer.wrap(buffer);
                InetSocketAddress source = (InetSocketAddress) channel.receive(input);
                if (source != null) receivePacket(source, buffer, input.position());
                boolean expired;
                synchronized (this) {
                    if (closed) return;
                    expired = peer != null && !disabled && System.nanoTime() - lastSeen >= 750_000_000L;
                    if (expired) disable("heartbeat-timeout");
                }
                if (expired) requestSync.run();
            } catch (Exception failure) {
                synchronized (this) {
                    if (closed) return;
                    disable("receive-error");
                }
                requestSync.run();
                return;
            }
        }
    }

    private void receivePacket(InetSocketAddress source, byte[] buffer, int size) throws IOException {
        if (!allowedAddress.equals(source.getAddress())) return;
        VideoDatagramCodec.Packet packet = protocol.decode(buffer, size);
        if (packet == null) return;
        boolean sync = false;
        if (packet.type == VideoDatagramCodec.HELLO && packet.payload.length == 24) {
            int mode;
            long latest;
            synchronized (this) {
                if (peer == null && !disabled) { peer = source; nonce = packet.nonce; sync = true; }
                if (!source.equals(peer) || nonce != packet.nonce || packet.sequence <= lastHello) return;
                // Recovery keeps the authenticated endpoint, nonce and increasing
                // sequence. Recorded HELLO/BYE packets cannot reopen an old path.
                if (disabled && packet.total == 1 && System.nanoTime() - disabledAt >= 1_000_000_000L) {
                    disabled = false;
                    active = false;
                    awaitingKey = true;
                    fallback = "";
                    feedback = null;
                    feedbackAt = 0;
                    sync = true;
                }
                lastHello = packet.sequence;
                lastSeen = System.nanoTime();
                updateFeedback(packet.payload, lastSeen);
                mode = disabled ? 0 : 3; // bit0 allowed; bit1 supports same-session recovery.
                latest = sequence;
            }
            byte[] status = ByteBuffer.allocate(8).putLong(latest).array();
            sendPacket(protocol.encode(VideoDatagramCodec.ACK, nonce, packet.sequence, 0, 0,
                    mode, status, 0, status.length), source);
        } else {
            synchronized (this) {
                if (peer == null || !source.equals(peer) || nonce != packet.nonce) return;
                if (packet.type == VideoDatagramCodec.BYE && packet.sequence > lastHello) {
                    lastHello = packet.sequence;
                    disable("client-fallback");
                    sync = true;
                }
                if (packet.type == VideoDatagramCodec.KEY && !disabled
                        && packet.sequence > lastKeySequence && System.nanoTime() - lastKeyAt >= 300_000_000L) {
                    lastKeySequence = packet.sequence; lastKeyAt = System.nanoTime(); sync = true;
                }
            }
            if (packet.type == VideoDatagramCodec.NACK) repair(packet, source);
        }
        if (sync) requestSync.run();
    }

    private synchronized void updateFeedback(byte[] bytes, long now) {
        ByteBuffer input = ByteBuffer.wrap(bytes);
        long received = input.getLong();
        long frames = input.getInt() & 0xffffffffL, lost = input.getInt() & 0xffffffffL;
        double rtt = (input.getInt() & 0xffffffffL) / 1000.0;
        double pressure = Math.min(2000, input.getInt() & 0xffffffffL);
        if (rtt > 0 && rtt < 3000) baselineRtt = Math.min(baselineRtt, rtt);
        if (feedbackAt > 0 && now - feedbackAt < 200_000_000L) return;
        long elapsed = feedbackAt == 0 ? 0 : now - feedbackAt;
        long count = Math.max(0, frames - previousFrames), loss = Math.max(0, lost - previousLoss);
        int goodput = elapsed <= 0 ? 0 : (int) Math.min(Integer.MAX_VALUE,
                Math.max(0, received - previousBytes) * 8_000_000_000L / elapsed);
        feedback = new NetworkFeedback(now, goodput, elapsed <= 0 ? 0 : (int) (count * 1_000_000_000L / elapsed),
                count + loss == 0 ? 0 : loss / (double) (count + loss), rtt,
                baselineRtt == Double.MAX_VALUE ? 0 : Math.max(0, rtt - baselineRtt), pressure);
        feedbackAt = now; previousBytes = received; previousFrames = frames; previousLoss = lost;
    }

    private void repair(VideoDatagramCodec.Packet packet, InetSocketAddress source) throws IOException {
        if (packet.payload.length < 2 || packet.payload.length > 64 || packet.payload.length % 2 != 0) return;
        final Cached frame;
        synchronized (this) {
            if (!active || disabled) return;
            prune(System.nanoTime());
            frame = cache.get(packet.sequence);
            if (frame == null) { unavailable(packet.sequence, source); return; }
        }
        ByteBuffer indexes = ByteBuffer.wrap(packet.payload);
        while (indexes.hasRemaining()) {
            int index = indexes.getShort() & 65535;
            if (index == 65535) {
                if (frame.retries.length > 64) { unavailable(packet.sequence, source); return; }
                for (int i = 0; i < frame.retries.length; i++) repairFragment(packet.sequence, frame, i, source);
            } else if (index < frame.retries.length) repairFragment(packet.sequence, frame, index, source);
        }
    }

    private synchronized void unavailable(long id, InetSocketAddress target) throws IOException {
        long now = System.nanoTime();
        if (now - lastUnavailableAt < 50_000_000L) return;
        lastUnavailableAt = now;
        // KEY total=1 is a negative repair acknowledgement, not a new frame.
        sendPacket(protocol.encode(VideoDatagramCodec.KEY, nonce, id, 0, 0, 1,
                new byte[0], 0, 0), target);
    }

    private void repairFragment(long id, Cached frame, int index, InetSocketAddress target) throws IOException {
        synchronized (this) {
            if (index >= frame.sentFragments || frame.retries[index] >= 2 || frame.repairs >= Math.min(64, frame.retries.length + 4)
                    || System.nanoTime() - frame.at > 150_000_000L) return;
        }
        int offset = index * VideoDatagramCodec.PAYLOAD;
        int length = Math.min(VideoDatagramCodec.PAYLOAD, frame.wire.length - offset);
        if (sendPacket(protocol.encode(VideoDatagramCodec.DATA, nonce, id, index, frame.retries.length,
                frame.wire.length, frame.wire, offset, length), target)) {
            synchronized (this) { frame.retries[index]++; frame.repairs++; retransmits++; }
        } else {
            synchronized (this) { repairWouldBlock++; }
        }
    }
    private boolean sendPacket(byte[] bytes, InetSocketAddress target) throws IOException {
        if (output.send(channel, bytes, target) == bytes.length) return true;
        synchronized (this) { sendWouldBlock++; }
        return false;
    }
    private void removeFirst() {
        Long key = cache.keySet().iterator().next();
        cachedBytes -= cache.remove(key).wire.length;
    }
    private void prune(long now) {
        while (!cache.isEmpty() && (cache.size() >= 16
                || now - cache.values().iterator().next().at > 150_000_000L)) removeFirst();
    }
    private void disable(String reason) {
        if (!disabled) disabledAt = System.nanoTime();
        disabled = true; active = false; fallback = reason; cache.clear(); cachedBytes = 0;
    }
    @Override public synchronized void close() {
        closed = true;
        disable("closed");
        try { channel.close(); } catch (IOException ignored) { }
        try { selector.close(); } catch (IOException ignored) { }
    }
}
