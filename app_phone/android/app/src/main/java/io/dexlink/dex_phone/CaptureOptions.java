package io.dexlink.dex_phone;

import java.io.DataInputStream;
import java.io.IOException;

/** Validated initial settings shared by the bridge and shell encoder. */
public final class CaptureOptions {
    public static final int VERSION = 2;
    public static final int TELEMETRY = 1;
    public static final int ADAPTIVE_BITRATE = 2;
    public static final int APP_WINDOWS = 4;
    public static final int PREFER_HEVC = 8;
    public static final int TARGET_FPS = 60;
    public final int fps;
    public final int maxSize;
    public final int bitrate;
    public final int features;

    public CaptureOptions(int fps, int maxSize, int bitrate) {
        this(fps, maxSize, bitrate, 0);
    }

    public CaptureOptions(int fps, int maxSize, int bitrate, int features) {
        if ((fps != 0 && fps < 15) || fps > 120 || maxSize < 640 || maxSize > 3840
                || bitrate < 2_000_000 || bitrate > 50_000_000 || features < 0 || features > 15) {
            throw new IllegalArgumentException("帧率、分辨率或码率超出支持范围");
        }
        // Accept old uncapped/high-refresh requests without making the encoder
        // produce work above the product's 60 FPS target.
        this.fps = fps == 0 ? TARGET_FPS : Math.min(fps, TARGET_FPS);
        this.maxSize = maxSize;
        this.bitrate = bitrate;
        this.features = features;
    }

    public static CaptureOptions read(DataInputStream input) throws IOException {
        int version = input.readInt();
        if (version != 1 && version != VERSION) throw new IllegalArgumentException("投屏设置协议版本不支持");
        int fps = input.readInt(), size = input.readInt(), bitrate = input.readInt();
        return new CaptureOptions(fps, size, bitrate, version == VERSION ? input.readInt() : 0);
    }

    public void write(java.io.DataOutputStream output) throws IOException {
        output.writeInt(VERSION);
        output.writeInt(fps);
        output.writeInt(maxSize);
        output.writeInt(bitrate);
        output.writeInt(features);
    }
}
