package io.dexlink.dex_phone.capture;

/** Small byte bursts are immediate; large access units get bounded pacing. */
final class VideoPacer {
    static final int CHUNK_BYTES = 8 * 1024;
    static final long MAX_WAIT_NS = 8_000_000L;
    private static final int BURST_BYTES = 16 * 1024;
    private int bitrate;
    private long scheduled;

    synchronized void setBitrate(int value) { bitrate = value; scheduled = 0; }

    synchronized long reserve(int bytes, long now, long budget) {
        if (bitrate <= 0) return 0;
        // Leave headroom for protocol overhead and imperfect encoder rate control.
        long rate = Math.max(1, bitrate * 115L / 800);
        // A normal 60 FPS picture must not wait solely because the selected
        // quality exceeds 8 Mbps. Pace bursts larger than one average frame.
        long burstBytes = Math.max(BURST_BYTES, (rate + 59) / 60);
        long burst = burstBytes * 1_000_000_000L / rate;
        if (scheduled == 0) scheduled = now - burst;
        long due = Math.max(scheduled, now - burst) + bytes * 1_000_000_000L / rate;
        long delay = Math.min(Math.max(0, budget), Math.max(0, due - now));
        // Never accumulate pacing debt across old pictures or a network stall.
        scheduled = Math.min(due, now + delay);
        return delay;
    }
}
