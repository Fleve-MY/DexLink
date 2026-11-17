package io.dexlink.dex_phone.capture;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Authenticated, MTU-sized access-unit fragments. Never transmits the token. */
final class VideoDatagramCodec {
    static final int MAGIC = 0x44585631, HEADER = 32, TAG = 16, PAYLOAD = 1152;
    static final int HELLO = 1, ACK = 2, DATA = 3, NACK = 4, BYE = 5, KEY = 6;
    static final int MAX_FRAME = 8 * 1024 * 1024;
    private final Mac mac;

    VideoDatagramCodec(String token) throws Exception {
        mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(token.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
    }

    synchronized byte[] encode(int type, long nonce, long sequence, int index, int count,
            int total, byte[] payload, int offset, int length) {
        ByteBuffer out = ByteBuffer.allocate(HEADER + length + TAG);
        out.putInt(MAGIC).put((byte) type).put(new byte[3]).putLong(nonce).putLong(sequence)
                .putShort((short) index).putShort((short) count).putInt(total);
        out.put(payload, offset, length);
        mac.update(out.array(), 0, HEADER + length);
        out.put(mac.doFinal(), 0, TAG);
        return out.array();
    }

    synchronized Packet decode(byte[] bytes, int size) {
        if (size < HEADER + TAG || size > HEADER + PAYLOAD + TAG) return null;
        ByteBuffer in = ByteBuffer.wrap(bytes, 0, size);
        if (in.getInt() != MAGIC) return null;
        int type = in.get() & 255;
        if (type < HELLO || type > KEY || in.get() != 0 || in.get() != 0 || in.get() != 0) return null;
        mac.update(bytes, 0, size - TAG);
        if (!MessageDigest.isEqual(Arrays.copyOf(mac.doFinal(), TAG),
                Arrays.copyOfRange(bytes, size - TAG, size))) return null;
        long nonce = in.getLong(), sequence = in.getLong();
        if (nonce <= 0 || sequence < 0) return null;
        int index = in.getShort() & 65535, count = in.getShort() & 65535, total = in.getInt();
        if (type == DATA && (total < 12 || total > MAX_FRAME || count != (total + PAYLOAD - 1) / PAYLOAD
                || index >= count || size - HEADER - TAG != Math.min(PAYLOAD, total - index * PAYLOAD))) return null;
        return new Packet(type, nonce, sequence, index, count, total,
                Arrays.copyOfRange(bytes, HEADER, size - TAG));
    }

    static final class Packet {
        final int type, index, count, total;
        final long nonce, sequence;
        final byte[] payload;
        Packet(int type, long nonce, long sequence, int index, int count, int total, byte[] payload) {
            this.type = type; this.nonce = nonce; this.sequence = sequence;
            this.index = index; this.count = count; this.total = total; this.payload = payload;
        }
    }
}
