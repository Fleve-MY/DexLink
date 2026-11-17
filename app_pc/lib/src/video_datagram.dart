import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dex_link/dex_link.dart';

class VideoDatagram {
  const VideoDatagram(
    this.type,
    this.nonce,
    this.sequence,
    this.index,
    this.count,
    this.total,
    this.payload,
  );
  final int type, nonce, sequence, index, count, total;
  final Uint8List payload;
}

/// Wire format shared with Android. Authentication precedes frame allocation.
class VideoDatagramCodec {
  VideoDatagramCodec(String token) : _mac = Hmac(sha256, utf8.encode(token));
  static const hello = 1, ack = 2, data = 3, nack = 4, bye = 5, key = 6;
  static const header = 32,
      tag = 16,
      payloadSize = 1152,
      maxFrame = 8 * 1024 * 1024;
  final Hmac _mac;

  Uint8List encode(
    int type,
    int nonce,
    int sequence, {
    int index = 0,
    int count = 0,
    int total = 0,
    List<int> payload = const [],
  }) {
    final out = Uint8List(header + payload.length + tag);
    final fields = ByteData.sublistView(out)
      ..setUint32(0, 0x44585631)
      ..setUint8(4, type)
      ..setInt64(8, nonce)
      ..setInt64(16, sequence)
      ..setUint16(24, index)
      ..setUint16(26, count)
      ..setUint32(28, total);
    out.setRange(header, header + payload.length, payload);
    out.setRange(
      out.length - tag,
      out.length,
      _mac
          .convert(Uint8List.sublistView(out, 0, out.length - tag))
          .bytes
          .take(tag),
    );
    assert(fields.lengthInBytes == out.length);
    return out;
  }

  VideoDatagram? decode(Uint8List bytes) {
    if (bytes.length < header + tag ||
        bytes.length > header + payloadSize + tag) {
      return null;
    }
    final fields = ByteData.sublistView(bytes);
    final type = fields.getUint8(4);
    if (fields.getUint32(0) != 0x44585631 ||
        type < hello ||
        type > key ||
        fields.getUint8(5) != 0 ||
        fields.getUint16(6) != 0) {
      return null;
    }
    final expected = _mac
        .convert(Uint8List.sublistView(bytes, 0, bytes.length - tag))
        .bytes;
    var difference = 0;
    for (var i = 0; i < tag; i++) {
      difference |= expected[i] ^ bytes[bytes.length - tag + i];
    }
    if (difference != 0) return null;
    final nonce = fields.getInt64(8), sequence = fields.getInt64(16);
    final index = fields.getUint16(24),
        count = fields.getUint16(26),
        total = fields.getUint32(28);
    if (nonce <= 0 || sequence < 0) return null;
    final payload = Uint8List.sublistView(bytes, header, bytes.length - tag);
    if (type == data &&
        (total < 12 ||
            total > maxFrame ||
            count != (total + payloadSize - 1) ~/ payloadSize ||
            index >= count ||
            payload.length !=
                (total - index * payloadSize).clamp(0, payloadSize))) {
      return null;
    }
    return VideoDatagram(type, nonce, sequence, index, count, total, payload);
  }
}

List<VideoPacket>? decodeVideoUnit(Uint8List wire) {
  final packets = <VideoPacket>[];
  var at = 0;
  while (at < wire.length) {
    if (packets.length >= 2 || at + 12 > wire.length) return null;
    final header = ByteData.sublistView(wire, at);
    final flags = header.getInt64(0), size = header.getUint32(8);
    if (flags < 0 || size == 0 || at + 12 + size > wire.length) return null;
    final config = flags & (1 << 62) != 0;
    if (config && (flags != 1 << 62 || packets.isNotEmpty)) return null;
    packets.add(
      VideoPacket(
        data: Uint8List.sublistView(wire, at + 12, at + 12 + size),
        pts: flags & ((1 << 61) - 1),
        config: config,
        keyFrame: flags & (1 << 61) != 0,
      ),
    );
    at += 12 + size;
  }
  if (packets.isEmpty ||
      packets.last.config ||
      (packets.length == 2 &&
          (!packets.first.config || !packets.last.keyFrame))) {
    return null;
  }
  return packets;
}

class _Assembly {
  _Assembly(VideoDatagram packet, this.createdUs)
    : bytes = Uint8List(packet.total),
      received = Uint8List(packet.count),
      requests = Uint8List(packet.count);
  final Uint8List bytes, received, requests;
  final int createdUs;
  int fragments = 0, lastNackUs = -100000;
  int highest = -1, lastFragmentUs = 0;
  int repairCursor = 0;
  List<VideoPacket>? packets;
}

/// Reorders references only for bounded repair; no timed playback/jitter queue.
class RealtimeVideoAssembler {
  RealtimeVideoAssembler({
    required this.onUnit,
    required this.onNack,
    required this.onNeedKey,
  });
  final void Function(List<VideoPacket>) onUnit;
  final void Function(int sequence, List<int> indexes) onNack;
  final void Function() onNeedKey;
  final _frames = <int, _Assembly>{};
  int _bytes = 0, _next = -1, _gapAt = -1, _gapNackAt = -100000;
  int _lastKeyAt = -1000000, _lastPts = -1;
  int deliveredBytes = 0,
      deliveredFrames = 0,
      lostFrames = 0,
      lastDelivered = 0;
  bool _waitingKey = true;
  bool get waitingKey => _waitingKey;
  int get bufferedBytes => _bytes;

  void add(VideoDatagram packet, int nowUs) {
    if (packet.type != VideoDatagramCodec.data ||
        packet.sequence <= lastDelivered) {
      return;
    }
    var frame = _frames[packet.sequence];
    if (frame == null) {
      if (_frames.length >= 12 ||
          _bytes + packet.total > VideoDatagramCodec.maxFrame) {
        _expire(nowUs);
      }
      frame = _Assembly(packet, nowUs);
      _frames[packet.sequence] = frame;
      _bytes += packet.total;
    }
    if (frame.bytes.length != packet.total ||
        frame.received.length != packet.count) {
      return;
    }
    if (nowUs - frame.createdUs > 80000) {
      _expire(nowUs);
      return;
    }
    if (frame.received[packet.index] == 0) {
      frame.bytes.setRange(
        packet.index * VideoDatagramCodec.payloadSize,
        packet.index * VideoDatagramCodec.payloadSize + packet.payload.length,
        packet.payload,
      );
      frame.received[packet.index] = 1;
      frame.fragments++;
      frame.highest = packet.index > frame.highest
          ? packet.index
          : frame.highest;
      frame.lastFragmentUs = nowUs;
    }
    if (!_waitingKey && packet.sequence > _next && _gapAt < 0) _gapAt = nowUs;
    if (frame.fragments == frame.received.length && frame.packets == null) {
      frame.packets = decodeVideoUnit(frame.bytes);
      if (frame.packets == null) {
        _expire(nowUs);
        return;
      }
      // A new IDR is independent of any missing older references. Do not
      // spend the repair deadline on a chain it has already replaced.
      if (!_waitingKey &&
          frame.packets!.last.keyFrame &&
          packet.sequence > _next &&
          frame.packets!.last.pts > _lastPts) {
        lostFrames += _frames.keys.where((id) => id < packet.sequence).length;
        for (final id
            in _frames.keys.where((id) => id < packet.sequence).toList()) {
          _remove(id);
        }
        _next = packet.sequence;
      }
      if (_waitingKey) {
        if (frame.packets!.last.keyFrame &&
            frame.packets!.last.pts > _lastPts) {
          _waitingKey = false;
          _next = packet.sequence;
          for (final id in _frames.keys.where((id) => id < _next).toList()) {
            _remove(id);
          }
        } else {
          _remove(packet.sequence);
          lostFrames++;
          _key(nowUs);
          return;
        }
      }
      _deliver(nowUs);
    }
  }

  void _remove(int id) {
    final frame = _frames.remove(id);
    if (frame != null) _bytes -= frame.bytes.length;
  }

  void _deliver(int nowUs) {
    while (!_waitingKey) {
      final frame = _frames[_next];
      if (frame?.packets == null) break;
      if (frame!.packets!.last.pts <= _lastPts ||
          nowUs - frame.createdUs > 80000) {
        _expire(nowUs);
        return;
      }
      lastDelivered = _next++;
      _lastPts = frame.packets!.last.pts;
      deliveredBytes += frame.bytes.length;
      deliveredFrames++;
      if (frame.packets!.last.keyFrame) _lastKeyAt = -1000000;
      _remove(lastDelivered);
      onUnit(frame.packets!);
      _gapAt = -1;
    }
    if (!_waitingKey && _frames.keys.any((id) => id > _next) && _gapAt < 0) {
      _gapAt = nowUs;
    }
  }

  void tick(int nowUs, double rttMs) {
    if (_frames.isEmpty && _gapAt < 0) return;
    final expected = _frames[_next];
    final age = expected == null
        ? (_gapAt < 0 ? 0 : nowUs - _gapAt)
        : nowUs - expected.createdUs;
    if (!_waitingKey && age >= 80000) {
      _expire(nowUs);
      return;
    }
    final interval = (rttMs * 1200).round().clamp(8000, 30000);
    if (expected != null && expected.packets == null) {
      if (age >= 4000) _repair(_next, expected, nowUs, interval);
    } else if (!_waitingKey &&
        _gapAt >= 0 &&
        age >= 4000 &&
        nowUs - _gapNackAt >= interval) {
      _gapNackAt = nowUs;
      onNack(_next, [65535]);
    }
    if (_waitingKey) {
      // The initial/recovery IDR also needs selective repair.
      for (final entry in _frames.entries.toList()) {
        final frame = entry.value;
        if (nowUs - frame.createdUs >= 80000) {
          _remove(entry.key);
          lostFrames++;
          _key(nowUs);
        } else if (nowUs - frame.createdUs >= 4000) {
          _repair(entry.key, frame, nowUs, interval);
        }
      }
    }
  }

  /// The authenticated sender no longer has this reference. Waiting for a
  /// repair timeout cannot recover it; replace the chain at a new IDR.
  void unavailable(int sequence, int nowUs) {
    if ((!_waitingKey && sequence == _next) ||
        (_waitingKey && _frames.containsKey(sequence))) {
      _expire(nowUs);
    }
  }

  void _repair(int id, _Assembly frame, int nowUs, int interval) {
    if (nowUs - frame.lastNackUs < interval) return;
    // Later fragments prove a hole. A still-arriving tail is not packet loss.
    final missing = <int>[];
    var inspected = 0;
    while (inspected < frame.received.length && missing.length < 32) {
      final i = frame.repairCursor;
      frame.repairCursor = (i + 1) % frame.received.length;
      inspected++;
      if (frame.received[i] == 0 &&
          frame.requests[i] < 2 &&
          (i < frame.highest || nowUs - frame.lastFragmentUs >= 8000)) {
        missing.add(i);
        frame.requests[i]++;
      }
    }
    if (missing.isEmpty) return;
    frame.lastNackUs = nowUs;
    onNack(id, missing);
  }

  void _key(int nowUs) {
    if (nowUs - _lastKeyAt >= 300000) {
      _lastKeyAt = nowUs;
      onNeedKey();
    }
  }

  void _expire(int nowUs) {
    if (!_waitingKey) lostFrames += _frames.length + 1;
    _frames.clear();
    _bytes = 0;
    _waitingKey = true;
    _gapAt = -1;
    _key(nowUs);
  }

  /// Transport switches cannot retain references from the previous carrier.
  void restart(int nowUs) => _expire(nowUs);
}
