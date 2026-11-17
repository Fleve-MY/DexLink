package io.dexlink.dex_phone.capture;

import org.json.JSONException;
import org.json.JSONObject;

/** Synchronized encoder/sender counters; durations describe stages, not their cause. */
final class CaptureMetrics {
    private long startedMs, sequence, packets, bytes, frames, sourceFrames, emptyPolls;
    private long waitNs, sendNs, maxSendNs, gapUs, previousPts = -1;

    CaptureMetrics(long nowMs) { startedMs = nowMs; }

    synchronized void waitSample(long nanos, boolean empty) {
        waitNs += nanos;
        if (empty) emptyPolls++;
    }

    synchronized void encoded(boolean config, long pts) {
        if (config) return;
        sourceFrames++;
        if (previousPts >= 0 && pts > previousPts) gapUs = Math.max(gapUs, pts - previousPts);
        previousPts = pts;
    }

    synchronized void sent(int size, long nanos, boolean config, long pts) {
        packets++; bytes += size + 12L;
        sendNs += nanos; maxSendNs = Math.max(maxSendNs, nanos);
        if (!config) {
            frames++;
        }
    }

    synchronized JSONObject snapshot(long nowMs, int bitrate, VideoSender sender) throws JSONException {
        if (nowMs - startedMs < 100) return null;
        JSONObject data = new JSONObject().put("sequence", ++sequence)
                .put("sampleTimeMs", nowMs)
                .put("windowMs", nowMs - startedMs).put("frames", frames)
                .put("sourceFrames", sourceFrames)
                .put("packets", packets).put("bytes", bytes).put("emptyPolls", emptyPolls)
                .put("waitMs", waitNs / 1_000_000.0).put("sendMs", sendNs / 1_000_000.0)
                .put("maxSendMs", maxSendNs / 1_000_000.0)
                .put("srcGapMaxMs", gapUs / 1000.0).put("bitrate", bitrate);
        startedMs = nowMs;
        packets = bytes = frames = sourceFrames = emptyPolls = waitNs = sendNs = maxSendNs = gapUs = 0;
        VideoSender.Stats stats = sender.stats(true);
        data.put("senderQueueMs", stats.oldestMs).put("senderWritingMs", stats.writingMs)
                .put("senderQueued", stats.queued).put("senderQueueBytes", stats.bytes)
                .put("senderDropped", stats.dropped);
        data.put("senderPeakQueueMs", stats.peakQueueMs).put("senderPeakWritingMs", stats.peakWritingMs);
        data.put("senderTcpWritingMs", stats.tcpWritingMs).put("senderTcpPeakWritingMs", stats.tcpPeakWritingMs);
        return data;
    }
}
