package io.dexlink.dex_phone.capture;

/** Emergency rate reduction stays local when Wi-Fi also delays control replies. */
public final class SenderBitrateControl {
    private final int floor, ceiling;
    private final boolean recover;
    private long badSince = -1, healthySince = -1, changedAt = -1, previousDrops;
    private int previousBitrate;
    private long lastFrameMs = -1, dynamicUntilMs = -1;

    public SenderBitrateControl(int ceiling, boolean recover) {
        this.ceiling = ceiling;
        this.floor = Math.min(ceiling, Math.max(2_000_000, ceiling / 4));
        this.recover = recover;
        previousBitrate = ceiling;
    }

    /** Called by the codec drain thread, never the blocked network writer. */
    public int sample(long nowMs, int current, VideoSender sender) {
        RealtimeVideoTransport.NetworkFeedback network = sender.networkFeedback();
        return sample(nowMs, current, sender.stats(), network);
    }

    public void frame(long nowMs) {
        if (lastFrameMs >= 0 && nowMs - lastFrameMs <= 50) dynamicUntilMs = nowMs + 250;
        lastFrameMs = nowMs;
    }

    int sample(long nowMs, int current, VideoSender.Stats stats) {
        return sample(nowMs, current, stats, null);
    }

    int sample(long nowMs, int current, VideoSender.Stats stats,
            RealtimeVideoTransport.NetworkFeedback network) {
        if (current != previousBitrate) {
            previousBitrate = current;
            badSince = healthySince = -1;
            changedAt = nowMs;
        }
        boolean lost = stats.dropped > previousDrops || (network != null && network.loss >= .02);
        previousDrops = stats.dropped;
        boolean bad = lost || stats.oldestMs >= 33 || stats.writingMs >= 50
                || (network != null && (network.rttGrowthMs >= 40 || network.receiverMs >= 50));
        badSince = bad ? (badSince < 0 ? nowMs : badSince) : -1;
        // Recovery is used by plain MediaProjection, which has no PC rate
        // acknowledgements. Privileged capture leaves recovery to the PC.
        healthySince = !bad && nowMs <= dynamicUntilMs
                ? (healthySince < 0 ? nowMs : healthySince) : -1;
        if ((changedAt < 0 || nowMs - changedAt >= 500) && current > floor
                && bad && (lost || stats.writingMs >= 100 || nowMs - badSince >= 100)) {
            int next = current * 4 / 5;
            if (network != null && network.frames >= 20 && network.goodput > 0) {
                next = Math.min(next, (int) (network.goodput * .9));
            }
            return changed(nowMs, Math.max(floor, next));
        }
        if (recover && current < ceiling && healthySince >= 0
                && nowMs - healthySince >= 8000 && nowMs - changedAt >= 8000) {
            return changed(nowMs, Math.min(ceiling, current + ceiling / 20));
        }
        return current;
    }

    private int changed(long nowMs, int next) {
        changedAt = nowMs;
        previousBitrate = next;
        badSince = healthySince = -1;
        return next;
    }
}
