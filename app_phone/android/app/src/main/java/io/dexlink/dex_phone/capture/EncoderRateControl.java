package io.dexlink.dex_phone.capture;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Build;

/** Keep screen-content bursts within the negotiated transport budget. */
public final class EncoderRateControl {
    private EncoderRateControl() { }

    public static void configure(MediaCodec codec, MediaFormat format) {
        apply(codec, format);
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        } catch (IllegalArgumentException unsupported) {
            if (Build.VERSION.SDK_INT < 29 || !format.containsKey(MediaFormat.KEY_BITRATE_MODE)) throw unsupported;
            // Some vendor codecs advertise a mode they reject for a specific
            // resolution/profile. Retry only this optional setting once.
            codec.reset();
            format.removeKey(MediaFormat.KEY_BITRATE_MODE);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            System.err.println("DexLink encoder retained default rate control: " + unsupported);
        }
    }

    private static void apply(MediaCodec codec, MediaFormat format) {
        // API 29 adds removal of optional keys for the vendor-rejection retry.
        // Keep the established default on older Android releases.
        if (Build.VERSION.SDK_INT < 29) return;
        try {
            MediaCodecInfo.EncoderCapabilities modes = codec.getCodecInfo()
                    .getCapabilitiesForType(format.getString(MediaFormat.KEY_MIME))
                    .getEncoderCapabilities();
            if (modes.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)) {
                format.setInteger(MediaFormat.KEY_BITRATE_MODE,
                        MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR);
            }
        } catch (RuntimeException unavailable) {
            // Older/vendor codecs may not expose encoder capabilities. Keep
            // their default mode instead of making capture unavailable.
            System.err.println("DexLink encoder rate control unavailable: " + unavailable);
        }
    }
}
