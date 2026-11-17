package io.dexlink.dex_phone.capture;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.os.Build;
import java.io.DataOutputStream;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

/** Optional shell playback capture; an audio error never terminates video. */
final class PhoneAudio implements AutoCloseable {
    private final Context context;
    private final Socket socket;
    private volatile boolean running = true;
    private volatile AudioRecord record;

    PhoneAudio(Context context, Socket socket) { this.context = context; this.socket = socket; }

    void start() {
        Thread thread = new Thread(this::capture, "dexlink-audio");
        thread.setDaemon(true);
        thread.start();
    }

    @android.annotation.SuppressLint({"MissingPermission", "WrongConstant", "BlockedPrivateApi", "SoonBlockedPrivateApi"})
    private void capture() {
        boolean headerSent = false;
        try {
            if (Build.VERSION.SDK_INT < 31) throw new IllegalStateException("系统音频转发需要 Android 12 或更高版本");
            AudioFormat format = new AudioFormat.Builder().setSampleRate(48000)
                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build();
            int minimum = AudioRecord.getMinBufferSize(48000, AudioFormat.CHANNEL_IN_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT);
            AudioRecord.Builder builder = new AudioRecord.Builder().setAudioSource(8)
                    .setAudioFormat(format).setBufferSizeInBytes(Math.max(15360, minimum * 2));
            // Supply shell attribution without app-process initialization.
            builder.getClass().getMethod("setContext", Context.class).invoke(builder, context);
            AudioRecord recorder = builder.build();
            record = recorder;
            if (!running) return;
            recorder.startRecording();
            if (recorder.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING)
                throw new IllegalStateException("手机拒绝系统音频采集");
            DataOutputStream output = new DataOutputStream(socket.getOutputStream());
            output.writeInt(0x444c4131); // DLA1: signed little-endian PCM
            output.writeInt(48000);
            output.writeInt(2);
            output.writeInt(16);
            headerSent = true;
            byte[] bytes = new byte[3840]; // at most 20 ms per packet
            while (running) {
                int count = recorder.read(bytes, 0, bytes.length, AudioRecord.READ_BLOCKING);
                if (count < 0) throw new IllegalStateException("音频读取失败：" + count);
                if (count == 0) continue;
                if (count % 4 != 0) throw new IllegalStateException("音频采样未对齐");
                output.writeInt(count);
                output.write(bytes, 0, count);
                output.flush();
            }
        } catch (Exception error) {
            if (running) {
                System.err.println("DexLink audio unavailable: " + error);
                if (!headerSent) {
                    try {
                        byte[] message = ("系统音频不可用：" + error).getBytes(StandardCharsets.UTF_8);
                        DataOutputStream output = new DataOutputStream(socket.getOutputStream());
                        output.writeInt(0x444c4531); // DLE1
                        output.writeInt(message.length);
                        output.write(message);
                        output.flush();
                    } catch (Exception ignored) { }
                }
            }
        } finally {
            close();
        }
    }

    public void close() {
        running = false;
        try { socket.close(); } catch (Exception ignored) { }
        AudioRecord recorder = record;
        if (recorder != null) {
            try { recorder.stop(); } catch (RuntimeException ignored) { }
            // The capture thread owns release, avoiding a read/release race.
            if (Thread.currentThread().getName().equals("dexlink-audio")) {
                recorder.release();
                record = null;
            }
        }
    }
}
