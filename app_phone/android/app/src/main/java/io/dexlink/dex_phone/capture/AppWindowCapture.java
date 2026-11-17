package io.dexlink.dex_phone.capture;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.view.Surface;
import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.nio.ByteBuffer;

/** One fullscreen Android display inside one PC-owned window. No OEM freeform transforms. */
@android.annotation.SuppressLint({"WrongConstant", "BlockedPrivateApi", "SoonBlockedPrivateApi"})
final class AppWindowCapture implements AutoCloseable {
    final DirectTransport transport;
    final String token = java.util.UUID.randomUUID().toString();
    volatile int width, height;
    private final java.util.concurrent.atomic.AtomicReference<AppDisplayProfile> pendingProfile = new java.util.concurrent.atomic.AtomicReference<>();
    private volatile AppDisplayProfile profile;
    private volatile boolean visible = true;
    private volatile int activeBitrate = 6_000_000;
    private final int fps;
    final int displayId;
    private final MediaCodec codec;
    private final VirtualDisplay display;
    private Surface surface;
    private final ShellControl input;
    private volatile boolean running = true;
    private ControlOutput output;
    private volatile VideoSender sender;
    private final java.util.concurrent.atomic.AtomicBoolean disposed = new java.util.concurrent.atomic.AtomicBoolean();
    volatile String error;

    AppWindowCapture(Context context, DisplayManager manager, String component, int fps, int width, int height) throws Exception {
        this(context, manager, component, fps, width, height, AppDisplayProfile.TABLET);
    }

    AppWindowCapture(Context context, DisplayManager manager, String component, int fps, int width, int height, String layout) throws Exception {
        this.fps = fps == 0 ? io.dexlink.dex_phone.CaptureOptions.TARGET_FPS
                : Math.min(fps, io.dexlink.dex_phone.CaptureOptions.TARGET_FPS);
        profile = AppDisplayProfile.create(width, height, layout);
        width = profile.width;
        height = profile.height;
        this.width = width;
        this.height = height;
        transport = new DirectTransport(token);
        MediaCodec encoder = null;
        VirtualDisplay screen = null;
        Surface target = null;
        try {
            encoder = MediaCodec.createEncoderByType("video/avc");
            EncoderRateControl.configure(encoder, format(width, height));
            target = encoder.createInputSurface();
            hintFrameRate(target);
            int flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
                    | DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
                    | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION | (1 << 10) | (1 << 8);
            if (Build.VERSION.SDK_INT >= 34) {
                screen = manager.createVirtualDisplay(new android.hardware.display.VirtualDisplayConfig.Builder(
                        "DexLink App", width, height, profile.density).setFlags(flags).setRequestedRefreshRate(this.fps).build());
            } else screen = manager.createVirtualDisplay("DexLink App", width, height, profile.density, null, flags);
            if (screen == null) throw new IllegalStateException("系统拒绝应用独立显示");
            displayId = screen.getDisplay().getDisplayId();
            codec = encoder;
            display = screen;
            surface = target;
            input = new ShellControl(context, manager, displayId, width, height, this::sync, null, this::setBitrate, null);
            // Fullscreen on a private display, never fullscreen on the PC desktop.
            ShellControl.runCommand("am", "start", "--display", Integer.toString(displayId),
                    "--windowingMode", "1", "-f", "0x18000000", "-n", component);
        } catch (Exception failure) {
            transport.close();
            if (screen != null) screen.release();
            if (encoder != null) encoder.release();
            if (target != null) target.release();
            throw failure;
        }
        Thread stream = new Thread(() -> {
            try { stream(); }
            catch (Exception failure) { if (running) error = failure.toString(); }
            finally { close(); }
        }, "dexlink-app-video-" + displayId);
        stream.setDaemon(true);
        stream.start();
    }

    private void sync() {
        try {
            Bundle request = new Bundle();
            request.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
            synchronized (codec) { codec.setParameters(request); }
        } catch (RuntimeException ignored) { }
    }

    private MediaFormat format(int width, int height) {
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, activeBitrate);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
        format.setFloat("max-fps-to-encoder", fps);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        format.setInteger(MediaFormat.KEY_LATENCY, 1);
        // Match the performance budget to the surface input ceiling.
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, fps);
        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline);
        if (Build.VERSION.SDK_INT >= 29) format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0);
        // A static app needs a heartbeat, not ten copies of its last frame each second.
        format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000);
        return format;
    }

    private void hintFrameRate(Surface target) {
        if (Build.VERSION.SDK_INT >= 30) {
            try { target.setFrameRate(fps, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT); }
            catch (RuntimeException unsupported) { System.err.println("DexLink app frame rate hint: " + unsupported); }
        }
    }

    private int setBitrate(int requested) {
        if (requested < 2_000_000 || requested > 6_000_000) throw new IllegalArgumentException("应用码率超出范围");
        synchronized (codec) {
            Bundle params = new Bundle();
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, requested);
            codec.setParameters(params);
            activeBitrate = requested;
            if (sender != null) sender.setBitrate(requested);
        }
        return requested;
    }

    void setVisible(boolean value) { visible = value; }

    private void restartEncoder(int width, int height, int density, boolean attached) {
        synchronized (codec) {
            display.setSurface(null);
            codec.stop();
            codec.reset();
            surface.release();
            EncoderRateControl.configure(codec, format(width, height));
            surface = codec.createInputSurface();
            hintFrameRate(surface);
            display.resize(width, height, density);
            codec.start();
            display.setSurface(attached ? surface : null);
        }
    }

    private void stream() throws Exception {
        transport.accept();
        if (!running) return;
        output = new ControlOutput(transport.control.getOutputStream(), true);
        Thread controls = new Thread(() -> {
            try { input.read(transport.control.getInputStream(), output); }
            catch (Exception failure) { if (running) error = failure.toString(); }
            finally { close(); }
        }, "dexlink-app-input-" + displayId);
        controls.setDaemon(true);
        controls.start();
        DataOutputStream writer = new DataOutputStream(new BufferedOutputStream(transport.video.getOutputStream(), 64 * 1024));
        transport.enableRealtime(this::sync);
        writer.write(new byte[64]);
        writer.writeInt(0x68323634);
        writer.writeInt(0x80000000 | 16 | 64 | (transport.realtime != null ? 128 : 0) | ((fps & 255) << 8));
        writer.writeInt(width);
        writer.writeInt(height);
        writer.flush();
        codec.start();
        display.setSurface(surface);
        sync();
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        CaptureMetrics metrics = new CaptureMetrics(android.os.SystemClock.elapsedRealtime());
        CaptureWatchdog watchdog = new CaptureWatchdog(android.os.SystemClock.elapsedRealtime());
        sender = new VideoSender(writer, this::sync, metrics::sent);
        sender.setBitrate(activeBitrate);
        sender.setRealtime(transport.realtime);
        SenderBitrateControl localRate = new SenderBitrateControl(6_000_000, false);
        boolean localRateSupported = true;
        boolean attached = true, waitForKey = false;
        while (running) {
            sender.checkFailure();
            long now = android.os.SystemClock.elapsedRealtime();
            synchronized (codec) {
                int next = localRateSupported ? localRate.sample(now, activeBitrate, sender) : activeBitrate;
                if (next != activeBitrate) {
                    try { setBitrate(next); }
                    catch (RuntimeException unsupported) {
                        localRateSupported = false;
                        System.err.println("DexLink app local bitrate adjustment: " + unsupported);
                    }
                }
            }
            org.json.JSONObject sample = metrics.snapshot(now, activeBitrate, sender);
            if (sample != null && transport.realtime != null) transport.realtime.telemetry(sample);
            if (sample != null) output.telemetry(sample.put("displayId", displayId).put("visible", visible)
                    .put("senderLocalRateControl", localRateSupported));
            if (attached != visible) {
                attached = visible;
                sender.reset();
                display.setSurface(attached ? surface : null);
                // Detach only this display. Some shared hardware encoders also
                // stall other active streams when one codec is suspended.
                if (attached) { waitForKey = true; hintFrameRate(surface); sync(); }
                watchdog.frame(now);
            }
            if (watchdog.recover(now, attached)) {
                System.err.println("DexLink app capture stalled: display=" + displayId + ", recovery=" + watchdog.attempts());
                sender.reset();
                waitForKey = true;
                if (watchdog.attempts() >= 2) restartEncoder(width, height, profile.density, true);
                else {
                    display.setSurface(null);
                    display.setSurface(surface);
                }
                hintFrameRate(surface);
                sync();
            }
            if (attached && watchdog.exhausted(now)) throw new IllegalStateException("应用采集持续无画面，请重新打开窗口");
            AppDisplayProfile requested = pendingProfile.getAndSet(null);
            if (requested != null) {
                int nextWidth = requested.width, nextHeight = requested.height;
                boolean pixelsChanged = nextWidth != width || nextHeight != height;
                boolean layoutChanged = requested.density != profile.density || !requested.layout.equals(profile.layout);
                if (pixelsChanged) {
                    sender.reset();
                    // Reconfigure only on the encoder thread. Keep the display
                    // and task alive so resizing does not relaunch the app.
                    restartEncoder(nextWidth, nextHeight, requested.density, attached);
                    watchdog.frame(now);
                    width = nextWidth;
                    height = nextHeight;
                    input.resizeVideo(nextWidth, nextHeight);
                }
                if (!pixelsChanged && layoutChanged) display.resize(width, height, requested.density);
                profile = requested;
                if (pixelsChanged || layoutChanged) {
                    output.json(21, new org.json.JSONObject().put("contentWidth", width).put("contentHeight", height)
                            .put("densityDpi", requested.density).put("layout", requested.layout)
                            .put("smallestWidthDp", requested.smallestWidthDp()));
                    sync();
                }
            }
            long waited = System.nanoTime();
            int slot = codec.dequeueOutputBuffer(info, 10_000);
            metrics.waitSample(System.nanoTime() - waited, slot == MediaCodec.INFO_TRY_AGAIN_LATER);
            if (slot < 0) continue;
            long header;
            byte[] bytes;
            try {
                if (info.size == 0) continue;
                boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                boolean key = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
                if (!config && (!attached || (waitForKey && !key))) continue;
                if (key) waitForKey = false;
                if (!config) watchdog.frame(android.os.SystemClock.elapsedRealtime());
                ByteBuffer data = codec.getOutputBuffer(slot);
                if (data == null) throw new IllegalStateException("应用编码器未返回数据");
                data.position(info.offset);
                data.limit(info.offset + info.size);
                bytes = new byte[info.size];
                data.get(bytes);
                header = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 ? 1L << 62
                        : info.presentationTimeUs | ((info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 ? 1L << 61 : 0);
            } finally { codec.releaseOutputBuffer(slot, false); }
            metrics.encoded((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0, info.presentationTimeUs);
            sender.offer(header, bytes);
        }
    }

    void resize(int width, int height) {
        resize(width, height, profile.layout);
    }

    void resize(int width, int height, String layout) {
        pendingProfile.set(AppDisplayProfile.create(width, height, layout));
    }

    AppDisplayProfile profile() { return profile; }

    boolean alive() { return running; }

    @Override public void close() {
        running = false;
        transport.close();
        // Only the video thread releases the codec; input/owner shutdown merely
        // cancels sockets so dequeue/write cannot race with release().
        if (!Thread.currentThread().getName().equals("dexlink-app-video-" + displayId)) return;
        if (!disposed.compareAndSet(false, true)) return;
        if (sender != null) { sender.close(); sender.awaitTermination(); }
        if (output != null) output.close();
        display.release();
        try { codec.stop(); } catch (RuntimeException ignored) { }
        codec.release();
        surface.release();
    }
}
