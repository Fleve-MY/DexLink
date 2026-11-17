package io.dexlink.dex_phone.capture;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;

/** HEVC is optional and hardware-only; a rejected candidate preserves AVC. */
public final class EncoderSelection {
    private EncoderSelection() { }
    public static final class Input {
        public final MediaCodec codec;
        public final android.view.Surface surface;
        Input(MediaCodec codec, android.view.Surface surface) { this.codec = codec; this.surface = surface; }
    }
    public static Input createInput(MediaFormat format, boolean hevc) throws java.io.IOException {
        MediaCodec codec = create(format, hevc);
        try { return new Input(codec, codec.createInputSurface()); }
        catch (RuntimeException rejected) {
            codec.release();
            if (!"video/hevc".equals(format.getString(MediaFormat.KEY_MIME))) throw rejected;
            System.err.println("DexLink HEVC surface rejected, using AVC: " + rejected);
            codec = create(format, false);
            try { return new Input(codec, codec.createInputSurface()); }
            catch (RuntimeException failure) { codec.release(); throw failure; }
        }
    }
    public static MediaCodec create(MediaFormat format, boolean hevc) throws java.io.IOException {
        if (hevc) {
            try {
                for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
                    if (!info.isEncoder()) continue;
                    String name = info.getName().toLowerCase(java.util.Locale.ROOT);
                    if (Build.VERSION.SDK_INT >= 29 ? !info.isHardwareAccelerated()
                            : name.startsWith("omx.google.") || name.startsWith("c2.android.") || name.startsWith("c2.google.")) continue;
                    boolean supports = false;
                    for (String type : info.getSupportedTypes()) if (type.equalsIgnoreCase("video/hevc")) supports = true;
                    if (!supports) continue;
                    MediaCodecInfo.CodecCapabilities caps = info.getCapabilitiesForType("video/hevc");
                    if (!caps.getVideoCapabilities().areSizeAndRateSupported(format.getInteger(MediaFormat.KEY_WIDTH),
                            format.getInteger(MediaFormat.KEY_HEIGHT), format.getInteger(MediaFormat.KEY_FRAME_RATE))) continue;
                    boolean surface = false;
                    for (int color : caps.colorFormats) if (color == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface) surface = true;
                    if (!surface) continue;
                    MediaCodec codec = null;
                    try {
                        format.setString(MediaFormat.KEY_MIME, "video/hevc");
                        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain);
                        codec = MediaCodec.createByCodecName(info.getName());
                        EncoderRateControl.configure(codec, format);
                        return codec;
                    } catch (Exception rejected) {
                        if (codec != null) codec.release();
                        System.err.println("DexLink HEVC candidate rejected: " + rejected);
                    }
                }
            } catch (RuntimeException unavailable) {
                System.err.println("DexLink HEVC capabilities unavailable: " + unavailable);
            }
        }
        format.setString(MediaFormat.KEY_MIME, "video/avc");
        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline);
        MediaCodec codec = MediaCodec.createEncoderByType("video/avc");
        try { EncoderRateControl.configure(codec, format); return codec; }
        catch (RuntimeException failure) { codec.release(); throw failure; }
    }
}
