package io.dexlink.dex_phone.capture;

import android.content.Context;
import android.graphics.Point;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Looper;
import android.view.Surface;
import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.io.DataInputStream;
import io.dexlink.dex_phone.CaptureOptions;
import java.net.InetAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/** DexLink's privileged capture entry point, loaded from our own APK by Shizuku. */
public final class CaptureMain {
    private volatile boolean running = true;
    private MediaCodec codec;
    private VirtualDisplay display;
    private Surface surface;
    private Socket video;
    private Socket control;
    private Socket ownerVideo;
    private Socket ownerControl;
    private DirectTransport direct;
    private PanelPower panelPower;
    private DisplayManager displayManager;
    private MediaFormat encoderFormat;
    private boolean mirror;
    private int captureWidth, captureHeight, captureDpi;
    private int targetFps;
    private PhoneAudio audio;
    private DesktopAppWindows appWindows;
    private ControlOutput controlOutput;
    private volatile VideoSender sender;
    private int features, maximumBitrate;
    private volatile int activeBitrate;

    public static void main(String[] args) {
        CaptureMain session = new CaptureMain();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            if (session.panelPower != null) session.panelPower.close();
        }, "dexlink-panel-restore"));
        int result = 0;
        try {
            Looper.prepareMainLooper();
            session.run(args);
        } catch (Throwable error) {
            // The owner or control reader may close video while drain is
            // writing its last frame. That is normal session shutdown.
            if (!(error instanceof java.net.SocketException && !session.running)) {
                error.printStackTrace(System.err);
                result = 1;
            }
        } finally {
            session.close();
        }
        System.exit(result);
    }

    // This entry runs only in shell app_process, where framework reflection is
    // allowed; it is never called inside the ordinary application process.
    // This entry runs as shell via app_process, outside app hidden-API policy.
    // The extra display flags are Android system flags absent from SDK IntDef.
    @android.annotation.SuppressLint({"BlockedPrivateApi", "SoonBlockedPrivateApi", "WrongConstant"})
    private void run(String[] args) throws Exception {
        if (args.length != 7 && args.length != 8) throw new IllegalArgumentException("Invalid DexLink capture arguments");
        boolean directMode = args.length == 8 && "direct".equals(args[7]);
        if (directMode) CaptureLog.install();
        int port = Integer.parseInt(args[0]);
        String token = args[1];
        boolean desktop = Boolean.parseBoolean(args[2]);
        int width = Integer.parseInt(args[3]);
        int height = Integer.parseInt(args[4]);
        int dpi = Integer.parseInt(args[5]);
        int bitrate = Math.max(4_000_000, Math.min(50_000_000, Integer.parseInt(args[6])));
        int captureFps = 60;

        // The shell package supplies attribution matching the shell UID. This is
        // a separate ART process: no Flutter engine or application is started.
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("systemMain").invoke(null);
        Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        Context context = system.createPackageContext("com.android.shell", Context.CONTEXT_IGNORE_SECURITY);
        // A context made by ActivityThread.systemMain() inherits the system
        // application's op package even after createPackageContext(). Align
        // attribution before services cache it (activities and clipboard check
        // the package against the real caller UID on recent Android versions).
        Class<?> contextImpl = Class.forName("android.app.ContextImpl");
        java.lang.reflect.Field opPackage = contextImpl.getDeclaredField("mOpPackageName");
        opPackage.setAccessible(true);
        opPackage.set(context, "com.android.shell");
        if (Build.VERSION.SDK_INT >= 31) {
            java.lang.reflect.Field attribution = contextImpl.getDeclaredField("mAttributionSource");
            attribution.setAccessible(true);
            android.content.AttributionSource.Builder builder =
                    new android.content.AttributionSource.Builder(android.os.Process.myUid())
                            .setPackageName("com.android.shell");
            if (Build.VERSION.SDK_INT >= 34) builder.setPid(android.os.Process.myPid());
            attribution.set(context, builder.build());
        }
        DisplayManager manager = context.getSystemService(DisplayManager.class);
        displayManager = manager;
        mirror = !desktop;
        video = connect(port, token, 'V');
        control = connect(port, token, 'C');
        // The bridge can advertise readiness before encoding. Wait for the
        // desktop's settings before allocating the codec and capture surface.
        if (directMode) {
            direct = new DirectTransport(token);
            ownerVideo = video;
            ownerControl = control;
            DataOutputStream ready = new DataOutputStream(ownerVideo.getOutputStream());
            ready.writeByte(3);
            ready.writeInt(direct.port());
            ready.flush();
            Thread lifetime = new Thread(() -> {
                try { while (ownerControl.getInputStream().read() >= 0) { } }
                catch (Exception ignored) { }
                finally {
                    running = false;
                    direct.close();
                    closeSocket(ownerVideo);
                    if (panelPower != null) panelPower.close();
                }
            }, "dexlink-owner");
            lifetime.setDaemon(true);
            lifetime.start();
        } else video.getOutputStream().write(1);
        int start = video.getInputStream().read();
        int maxSize = 2560;
        if (start == 2) {
            CaptureOptions options = CaptureOptions.read(new DataInputStream(video.getInputStream()));
            captureFps = options.fps;
            maxSize = options.maxSize;
            bitrate = options.bitrate;
            features = options.features;
        } else if (start != 1) return;
        if (directMode) {
            direct.accept();
            video = direct.video;
            control = direct.control;
        }
        if (!desktop) {
            Point size = new Point();
            manager.getDisplay(0).getRealSize(size);
            double scale = Math.min(1.0, (double) maxSize / Math.max(size.x, size.y));
            width = ((int) (size.x * scale)) & ~1;
            height = ((int) (size.y * scale)) & ~1;
            dpi = context.getResources().getDisplayMetrics().densityDpi;
        } else if (start == 2) {
            double scale = Math.min(1.0, (double) maxSize / Math.max(width, height));
            width = ((int) (width * scale)) & ~1;
            height = ((int) (height * scale)) & ~1;
        }
        if (width < 2 || height < 2 || width > 3840 || height > 3840) {
            throw new IllegalArgumentException("Invalid capture dimensions");
        }
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        activeBitrate = maximumBitrate = bitrate;
        format.setInteger(MediaFormat.KEY_FRAME_RATE, captureFps);
        // Cap surface input too: KEY_FRAME_RATE alone is only stream metadata.
        format.setFloat("max-fps-to-encoder", captureFps);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        format.setInteger(MediaFormat.KEY_LATENCY, 1);
        // Provision the encoder for the same bounded surface rate.
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, captureFps);
        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline);
        if (Build.VERSION.SDK_INT >= 29) format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0);
        // Idle frames are a keepalive, not a way to manufacture the target FPS.
        format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER,
                desktop && (features & CaptureOptions.APP_WINDOWS) != 0 ? 1_000_000L : 100_000L);
        EncoderSelection.Input input = EncoderSelection.createInput(format, (features & CaptureOptions.PREFER_HEVC) != 0);
        codec = input.codec;
        encoderFormat = format;
        captureWidth = width;
        captureHeight = height;
        captureDpi = dpi;
        targetFps = captureFps;
        surface = input.surface;
        requestSurfaceRate();
        int flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC;
        flags |= DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
                | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
                | (1 << 10) // TRUSTED: shell-created interactive display
                | (1 << 8); // Destroy this display's tasks when the session ends.
        if (desktop) {
            if (Build.VERSION.SDK_INT >= 34) {
                try {
                    display = manager.createVirtualDisplay(new android.hardware.display.VirtualDisplayConfig.Builder(
                            "DexLink Desktop", width, height, dpi).setFlags(flags)
                            .setRequestedRefreshRate(targetFps).build());
                } catch (RuntimeException unsupported) {
                    System.err.println("DexLink desktop refresh request unavailable: " + unsupported);
                }
            }
            if (display == null) display = manager.createVirtualDisplay("DexLink Desktop", width, height, dpi, null, flags);
        } else {
            // A mirror is a capture sink, not a public presentation display.
            // Bind it explicitly to display 0 so launching apps/Home cannot
            // give it its own windows and override automatic mirroring.
            display = createMirror();
        }
        if (display == null) throw new IllegalStateException("Android refused the DexLink display");
        int targetDisplay = desktop ? display.getDisplay().getDisplayId() : 0;
        try {
            panelPower = new PanelPower(context);
        } catch (Exception unavailable) {
            System.err.println("DexLink panel control unavailable: " + unavailable);
        }
        controlOutput = new ControlOutput(control.getOutputStream(), (features & CaptureOptions.TELEMETRY) != 0);
        if (desktop && (features & CaptureOptions.APP_WINDOWS) != 0) {
            appWindows = new DesktopAppWindows(context, manager, width, height, targetFps);
        }
        ShellControl executor = new ShellControl(context, manager, targetDisplay, width, height, this::requestSync, panelPower,
                (features & CaptureOptions.ADAPTIVE_BITRATE) != 0 ? this::setBitrate : null,
                desktop ? new DesktopControl(context, targetDisplay, width, height, appWindows) : null);
        if (desktop) executor.startHome();
        Thread controlThread = new Thread(() -> {
            try {
                executor.read(control.getInputStream(), controlOutput);
            } catch (Exception error) {
                if (running) System.err.println("DexLink control: " + error);
            } finally {
                running = false;
                if (panelPower != null) panelPower.close();
                closeSocket(video);
            }
        }, "dexlink-input");
        controlThread.setDaemon(true);
        controlThread.start();
        System.out.println("DexLink capture ready: " + width + "x" + height + ", " + codec.getName()
                + ", display=" + targetDisplay);
        // Keep the display detached until the PC consumes video. Otherwise the
        // first connection receives a burst of old frames and can drop its IDR.
        codec.start();
        display.setSurface(surface);
        if (direct != null && direct.audio != null) {
            audio = new PhoneAudio(context, direct.audio);
            audio.start();
        }
        System.out.println("DexLink display rate=" + display.getDisplay().getRefreshRate()
                + ", source rate=" + manager.getDisplay(0).getRefreshRate() + ", requested=" + targetFps);

        DataOutputStream output = new DataOutputStream(new BufferedOutputStream(video.getOutputStream(), 64 * 1024));
        if (direct != null) direct.enableRealtime(this::requestSync);
        byte[] name = new byte[64];
        byte[] model = Build.MODEL.getBytes(StandardCharsets.UTF_8);
        System.arraycopy(model, 0, name, 0, Math.min(63, model.length));
        output.write(name);
        output.writeInt("video/hevc".equals(format.getString(MediaFormat.KEY_MIME)) ? 0x68323635 : 0x68323634);
        output.writeInt(0x80000000 | (desktop ? 9 : 0) | (panelPower != null ? 2 : 0)
                | ((features & CaptureOptions.ADAPTIVE_BITRATE) != 0 ? 16 : 0)
                | (appWindows != null ? 32 : 0)
                | (direct != null && direct.realtime != null ? 128 : 0)
                | ((captureFps & 255) << 8));
        output.writeInt(width);
        output.writeInt(height);
        output.flush();
        requestSync();
        drain(output);
    }

    private static Socket connect(int port, String token, int channel) throws Exception {
        Socket socket = new Socket(InetAddress.getByName("127.0.0.1"), port);
        socket.setTcpNoDelay(true);
        DataOutputStream auth = new DataOutputStream(socket.getOutputStream());
        auth.writeUTF(token);
        auth.writeByte(channel);
        auth.flush();
        return socket;
    }

    private void requestSync() {
        try {
            Bundle params = new Bundle();
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
            codec.setParameters(params);
        } catch (RuntimeException ignored) {
            // A control event may race with encoder shutdown.
        }
    }

    private synchronized int setBitrate(int requested) {
        if (requested < 2_000_000 || requested > maximumBitrate) {
            throw new IllegalArgumentException("动态码率超出本次会话范围");
        }
        Bundle params = new Bundle();
        params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, requested);
        codec.setParameters(params);
        activeBitrate = requested;
        if (sender != null) sender.setBitrate(requested);
        System.out.println("DexLink video bitrate=" + requested);
        return requested;
    }

    private void drain(DataOutputStream output) throws Exception {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        int frames = 0;
        CaptureMetrics metrics = new CaptureMetrics(android.os.SystemClock.elapsedRealtime());
        sender = new VideoSender(output, this::requestSync, metrics::sent);
        sender.setBitrate(activeBitrate);
        if (direct != null) sender.setRealtime(direct.realtime);
        SenderBitrateControl localRate = new SenderBitrateControl(maximumBitrate, false);
        boolean localRateSupported = (features & CaptureOptions.ADAPTIVE_BITRATE) != 0;
        CaptureWatchdog watchdog = new CaptureWatchdog(android.os.SystemClock.elapsedRealtime());
        DeviceState deviceState = new DeviceState();
        long nextStateCheck = 0;
        boolean interactive = true;
        boolean locked = false;
        long statsAt = android.os.SystemClock.elapsedRealtime();
        int statsFrames = 0;
        long waitNs = 0, maxFrameGapUs = 0, previousPts = -1;
        while (running) {
            sender.checkFailure();
            long now = android.os.SystemClock.elapsedRealtime();
            if (localRateSupported) {
                synchronized (this) {
                    int next = localRate.sample(now, activeBitrate, sender);
                    if (next != activeBitrate) {
                        try { setBitrate(next); }
                        catch (RuntimeException unsupported) {
                            localRateSupported = false;
                            System.err.println("DexLink local bitrate adjustment: " + unsupported);
                        }
                    }
                }
            }
            org.json.JSONObject sample = metrics.snapshot(now, activeBitrate, sender);
            if (sample != null) {
                if (direct != null && direct.realtime != null) direct.realtime.telemetry(sample);
                sample.put("senderLocalRateControl", localRateSupported);
                android.view.Display source = displayManager.getDisplay(0);
                controlOutput.telemetry(sample.put("sourceRefreshHz", source == null ? 0 : source.getRefreshRate())
                        .put("requestedRefreshHz", targetFps));
            }
            boolean stateChecked = now >= nextStateCheck;
            if (stateChecked) {
                nextStateCheck = now + 250;
                DeviceState.State state = deviceState.read();
                interactive = state.interactive;
                locked = state.locked;
                if (panelPower != null) panelPower.screenState(interactive, locked);
            }
            long waitStart = System.nanoTime();
            int index = codec.dequeueOutputBuffer(info, 10_000);
            long waitedNs = System.nanoTime() - waitStart;
            waitNs += waitedNs;
            metrics.waitSample(waitedNs, index == MediaCodec.INFO_TRY_AGAIN_LATER);
            if (index < 0) {
                if (stateChecked) {
                    // Physical locking may suspend capture legitimately. Resume
                    // recovery only after unlock; never dismiss the lockscreen.
                    if (mirror && watchdog.recover(now, interactive && !locked)) {
                        System.err.println("DexLink capture stalled: recovery " + watchdog.attempts());
                        recoverMirror(watchdog.attempts() >= 2);
                    }
                    if (mirror && interactive && !locked && watchdog.exhausted(now)) {
                        throw new IllegalStateException("Mirror capture stopped producing frames after three recovery attempts");
                    }
                }
                continue;
            }
            boolean released = false;
            try {
                if (info.size == 0) continue;
                if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                    watchdog.frame(android.os.SystemClock.elapsedRealtime());
                    if (previousPts >= 0 && info.presentationTimeUs > previousPts) {
                        maxFrameGapUs = Math.max(maxFrameGapUs, info.presentationTimeUs - previousPts);
                    }
                    previousPts = info.presentationTimeUs;
                }
                ByteBuffer buffer = codec.getOutputBuffer(index);
                if (buffer == null) throw new IllegalStateException("Missing encoder buffer");
                buffer.position(info.offset);
                buffer.limit(info.offset + info.size);
                long header = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        ? 1L << 62 : info.presentationTimeUs
                        | ((info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 ? 1L << 61 : 0);
                byte[] bytes = new byte[info.size];
                buffer.get(bytes);
                // A blocked Wi-Fi write must not retain a MediaCodec output
                // slot and prevent the encoder from accepting new input.
                codec.releaseOutputBuffer(index, false);
                released = true;
                metrics.encoded((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0, info.presentationTimeUs);
                sender.offer(header, bytes);
                if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && ++frames % 180 == 0) {
                    System.out.println("DexLink video frames=" + frames);
                }
                long statsNow = android.os.SystemClock.elapsedRealtime();
                if (statsNow - statsAt >= 5000) {
                    System.out.println("DexLink capture fps=" + (frames - statsFrames) * 1000.0 / (statsNow - statsAt));
                    System.out.println("DexLink timing encoderWaitMs=" + waitNs / 1_000_000
                            + ", senderQueueMs=" + sender.stats().oldestMs
                            + ", senderDropped=" + sender.stats().dropped
                            + ", maxSourceGapMs=" + maxFrameGapUs / 1000 + ", targetFps=" + targetFps);
                    waitNs = maxFrameGapUs = 0;
                    statsFrames = frames;
                    statsAt = statsNow;
                }
            } finally {
                if (!released) codec.releaseOutputBuffer(index, false);
            }
        }
    }

    @android.annotation.SuppressLint({"BlockedPrivateApi", "SoonBlockedPrivateApi"})
    private VirtualDisplay createMirror() throws Exception {
        VirtualDisplay result;
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                android.hardware.display.VirtualDisplayConfig.Builder builder =
                        new android.hardware.display.VirtualDisplayConfig.Builder(
                                "DexLink Mirror", captureWidth, captureHeight, 1)
                                .setFlags(DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR)
                                .setRequestedRefreshRate(targetFps);
                builder.getClass().getMethod("setDisplayIdToMirror", int.class).invoke(builder, 0);
                result = displayManager.createVirtualDisplay(builder.build());
                if (result == null) throw new IllegalStateException("Android refused mirror display");
                return result;
            } catch (Exception unsupported) {
                // A refresh-rate hint is optional; retain the proven mirror
                // path if a vendor rejects the newer display configuration.
                System.err.println("DexLink display rate request unavailable: " + unsupported);
            }
        }
        try {
            result = (VirtualDisplay) DisplayManager.class.getMethod("createVirtualDisplay",
                    String.class, int.class, int.class, int.class, Surface.class)
                    .invoke(null, "DexLink Mirror", captureWidth, captureHeight, 0, null);
        } catch (NoSuchMethodException olderAndroid) {
            result = displayManager.createVirtualDisplay("DexLink Mirror", captureWidth, captureHeight,
                    captureDpi, null, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR);
        }
        if (result == null) throw new IllegalStateException("Android refused mirror recovery");
        return result;
    }

    private void recoverMirror(boolean restartCodec) throws Exception {
        if (sender != null) sender.reset();
        // Keep the same encoded dimensions and TCP session. A fresh mirror
        // rebinds display 0 after a ROM display transition; if it is insufficient,
        // restart the encoder and publish fresh SPS/PPS plus IDR on the same wire.
        if (display != null) { display.release(); display = null; }
        if (restartCodec) {
            codec.stop();
            if (surface != null) surface.release();
            encoderFormat.setInteger(MediaFormat.KEY_BIT_RATE, activeBitrate);
            EncoderRateControl.configure(codec, encoderFormat);
            surface = codec.createInputSurface();
            requestSurfaceRate();
            codec.start();
        }
        display = createMirror();
        display.setSurface(surface);
        requestSync();
    }

    private void close() {
        running = false;
        if (sender != null) sender.close();
        if (appWindows != null) appWindows.close();
        if (audio != null) audio.close();
        if (panelPower != null) panelPower.close();
        closeSocket(video);
        if (sender != null) sender.awaitTermination();
        closeSocket(control);
        if (controlOutput != null) controlOutput.close();
        if (direct != null) direct.close();
        closeSocket(ownerVideo);
        closeSocket(ownerControl);
        if (display != null) display.release();
        if (codec != null) {
            try { codec.stop(); } catch (RuntimeException ignored) { }
            codec.release();
        }
        if (surface != null) surface.release();
        System.out.println("DexLink capture stopped");
    }

    private void requestSurfaceRate() {
        if (Build.VERSION.SDK_INT >= 30) {
            try { surface.setFrameRate(targetFps, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT); }
            catch (RuntimeException unsupported) {
                System.err.println("DexLink surface frame rate request unavailable: " + unsupported);
            }
        }
    }

    private static void closeSocket(Socket socket) {
        try { if (socket != null) socket.close(); } catch (Exception ignored) { }
    }
}
