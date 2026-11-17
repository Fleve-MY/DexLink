import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dex_link/dex_link.dart';

import 'video_datagram.dart';

/// Authenticated video-only UDP. Control/audio and the fallback remain TCP.
class RealtimeVideoClient {
  RealtimeVideoClient._(
    this._socket,
    this._address,
    this._port,
    String token,
    void Function(List<VideoPacket>) onUnit,
    this._fallback,
  ) : _codec = VideoDatagramCodec(token) {
    final random = Random.secure();
    _nonce = (random.nextInt(1 << 30) << 32) | random.nextInt(1 << 32) | 1;
    _assembler = RealtimeVideoAssembler(
      onUnit: (unit) {
        _progressAt = _clock.elapsedMicroseconds;
        onUnit(unit);
      },
      onNack: (sequence, indexes) {
        final payload = ByteData(indexes.length * 2);
        for (var i = 0; i < indexes.length; i++) {
          payload.setUint16(i * 2, indexes[i]);
        }
        _send(
          _codec.encode(
            VideoDatagramCodec.nack,
            _nonce,
            sequence,
            payload: payload.buffer.asUint8List(),
          ),
        );
        nackRequests++;
      },
      onNeedKey: () {
        if (_closed || _suspended) return;
        _send(_codec.encode(VideoDatagramCodec.key, _nonce, ++_helloSequence));
      },
    );
    _subscription = _socket.listen((event) {
      if (event == RawSocketEvent.read) {
        Datagram? datagram;
        while (!_closed && (datagram = _socket.receive()) != null) {
          _receive(datagram!);
        }
      } else if (event == RawSocketEvent.closed) {
        fallback('udp-closed');
      }
    }, onError: (Object error) => fallback('udp-error'));
    _heartbeat();
    _timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final now = _clock.elapsedMicroseconds;
      if (_suspended) {
        if (!_probing && now < _retryAt) {
          // One emergency probe per session when the reliable fallback also
          // stopped delivering. Flowing TCP keeps the normal retry backoff.
          if (_earlyRetryUsed ||
              now - _suspendedAt < 1000000 ||
              now - _reliableAt < 750000) {
            return;
          }
          _earlyRetryUsed = true;
          _earlyProbing = true;
        }
        if (!_probing) {
          _probing = true;
          _probeAt = now;
          _heartbeatAt = now - 200000;
        }
        if (now - _probeAt >= 750000) {
          if (_earlyProbing) {
            _earlyProbing = false;
            _probing = false;
            _hellos.clear();
            _send(
              _codec.encode(VideoDatagramCodec.bye, _nonce, ++_helloSequence),
            );
          } else {
            _pauseRetry(now);
          }
        } else if (now - _heartbeatAt >= 200000) {
          _heartbeat(recovery: true);
        }
        return;
      }
      if (now - _heartbeatAt >= 200000) _heartbeat();
      if (now - _lastAckAt >= 750000) {
        fallback('udp-heartbeat-timeout');
        return;
      }
      if (_serverSequence > _assembler.lastDelivered &&
          now - _progressAt > 1500000) {
        fallback('udp-video-timeout');
        return;
      }
      _assembler.tick(now, rttMs);
      if (now - _healthAt >= 1000000) {
        final delivered = _assembler.deliveredFrames - _healthDelivered;
        final lost = _assembler.lostFrames - _healthLost;
        final total = delivered + lost;
        _unhealthyWindows = total >= 20 && lost / total >= .10
            ? _unhealthyWindows + 1
            : 0;
        _healthAt = now;
        _healthDelivered = _assembler.deliveredFrames;
        _healthLost = _assembler.lostFrames;
        if (_unhealthyWindows >= 2) fallback('udp-sustained-loss');
      }
    });
  }

  static Future<RealtimeVideoClient> connect({
    required InternetAddress address,
    required int port,
    required String token,
    required void Function(List<VideoPacket>) onUnit,
    required void Function(String) onFallback,
  }) async {
    final socket = await RawDatagramSocket.bind(
      address.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    try {
      final option = Platform.isWindows
          ? 0x1002
          : Platform.isLinux
          ? 8
          : 0x1002;
      socket.setRawOption(
        RawSocketOption.fromInt(
          RawSocketOption.levelSocket,
          option,
          512 * 1024,
        ),
      );
    } on SocketException {
      /* Keep the system buffer when tuning is rejected. */
    }
    return RealtimeVideoClient._(
      socket,
      address,
      port,
      token,
      onUnit,
      onFallback,
    );
  }

  final RawDatagramSocket _socket;
  final InternetAddress _address;
  final int _port;
  final VideoDatagramCodec _codec;
  final void Function(String) _fallback;
  final _clock = Stopwatch()..start();
  late final RealtimeVideoAssembler _assembler;
  late final int _nonce;
  late final StreamSubscription<RawSocketEvent> _subscription;
  Timer? _timer;
  bool _closed = false;
  bool _suspended = false, _probing = false, _canRecover = false;
  bool _earlyRetryUsed = false, _earlyProbing = false;
  int _suspendedAt = 0, _reliableAt = -1000000;
  int _retryAt = 0, _probeAt = 0, _retryCount = 0, _recovered = 0;
  int _helloSequence = 0,
      _lastAckSequence = 0,
      _lastAckAt = 0,
      _heartbeatAt = 0;
  int _serverSequence = 0,
      _progressAt = 0,
      nackRequests = 0,
      invalidPackets = 0;
  int _healthAt = 0,
      _healthDelivered = 0,
      _healthLost = 0,
      _unhealthyWindows = 0;
  final _hellos = <int, int>{};
  double rttMs = 0, receiverOldestMs = 0;
  double _minimumRttMs = double.infinity;
  int _congestedUntilUs = 0, _observedLoss = 0;
  int _lastLossUs = -2000000, _slowRepairAcks = 0;
  bool get congested =>
      !_closed &&
      (_suspended ||
          _clock.elapsedMicroseconds < _congestedUntilUs ||
          rttMs >= _minimumRttMs + 20 ||
          _assembler.waitingKey);
  String fallbackReason = '';
  Map<String, Object> get stats => {
    'udpRttMs': rttMs,
    'udpDelivered': _assembler.deliveredFrames,
    'udpLost': _assembler.lostFrames,
    'udpNacks': nackRequests,
    'udpBufferedBytes': _assembler.bufferedBytes,
    'udpInvalid': invalidPackets,
    'udpFallback': fallbackReason,
    'udpRecoveries': _recovered,
    'udpProbing': _probing,
  };

  void _send(Uint8List bytes) {
    if (!_closed) {
      try {
        _socket.send(bytes, _address, _port);
      } on SocketException {
        fallback('udp-send-error');
      }
    }
  }

  void _heartbeat({bool recovery = false}) {
    final now = _clock.elapsedMicroseconds;
    if (_assembler.lostFrames > _observedLoss) {
      _observedLoss = _assembler.lostFrames;
      _lastLossUs = now;
      _congestedUntilUs = now + 2000000;
    }
    _heartbeatAt = now;
    _hellos[++_helloSequence] = now;
    while (_hellos.length > 8) {
      _hellos.remove(_hellos.keys.first);
    }
    final counters = ByteData(24)
      ..setInt64(0, _assembler.deliveredBytes)
      ..setUint32(8, _assembler.deliveredFrames)
      ..setUint32(12, _assembler.lostFrames)
      ..setUint32(16, (rttMs * 1000).round().clamp(0, 3000000))
      ..setUint32(20, receiverOldestMs.round().clamp(0, 2000));
    _send(
      _codec.encode(
        VideoDatagramCodec.hello,
        _nonce,
        _helloSequence,
        total: recovery ? 1 : 0,
        payload: counters.buffer.asUint8List(),
      ),
    );
  }

  void _receive(Datagram datagram) {
    if (datagram.address.address != _address.address ||
        datagram.port != _port) {
      return;
    }
    final packet = _codec.decode(datagram.data);
    if (packet == null || packet.nonce != _nonce) {
      invalidPackets++;
      return;
    }
    final now = _clock.elapsedMicroseconds;
    if (packet.type == VideoDatagramCodec.ack && packet.payload.length == 8) {
      final sent = _hellos.remove(packet.sequence);
      if (sent == null || packet.sequence <= _lastAckSequence) return;
      _lastAckSequence = packet.sequence;
      _lastAckAt = now;
      _canRecover = packet.total & 2 != 0 || _canRecover;
      final measured = (now - sent) / 1000;
      // If a whole repair round trip exceeds the reference lifetime, recent
      // chain loss cannot be repaired in time. Avoid repeated IDR freezes.
      _slowRepairAcks = measured >= 80 ? _slowRepairAcks + 1 : 0;
      _minimumRttMs = min(_minimumRttMs, measured);
      rttMs = rttMs == 0 ? measured : rttMs * .8 + measured * .2;
      _serverSequence = ByteData.sublistView(packet.payload).getInt64(0);
      if (!_suspended && _slowRepairAcks >= 2 && now - _lastLossUs < 2000000) {
        fallback('udp-repair-rtt');
        return;
      }
      if (_suspended) {
        if (_probing && packet.total & 1 != 0) {
          _suspended = false;
          _probing = false;
          _earlyProbing = false;
          _progressAt = now;
          _congestedUntilUs = now + 2000000;
          _healthAt = now;
          _healthDelivered = _assembler.deliveredFrames;
          _healthLost = _assembler.lostFrames;
          _unhealthyWindows = 0;
          _slowRepairAcks = 0;
          _recovered++;
          fallbackReason = '';
        }
      } else if (packet.total & 1 == 0) {
        fallback('phone-tcp-fallback');
      }
    } else if (packet.type == VideoDatagramCodec.data) {
      if (_suspended) return;
      _assembler.add(packet, now);
    } else if (packet.type == VideoDatagramCodec.key &&
        packet.total == 1 &&
        packet.payload.isEmpty) {
      _assembler.unavailable(packet.sequence, now);
    }
  }

  void fallback(String reason) {
    if (_closed) return;
    if (_suspended) {
      close();
      return;
    }
    fallbackReason = reason;
    if (_canRecover &&
        (reason == 'udp-heartbeat-timeout' ||
            reason == 'udp-video-timeout' ||
            reason == 'phone-tcp-fallback' ||
            reason == 'phone-resumed-tcp')) {
      _suspended = true;
      _suspendedAt = _clock.elapsedMicroseconds;
      _assembler.restart(_clock.elapsedMicroseconds);
      _pauseRetry(_clock.elapsedMicroseconds);
    } else {
      close();
    }
    _fallback(reason);
  }

  void _pauseRetry(int now) {
    _probing = false;
    _hellos.clear();
    final delaySeconds = min(30, 5 * (1 << min(_retryCount++, 3)));
    _retryAt = now + delaySeconds * 1000000;
    _send(_codec.encode(VideoDatagramCodec.bye, _nonce, ++_helloSequence));
  }

  void requireKeyframe() {
    if (!_closed && !_suspended) _assembler.restart(_clock.elapsedMicroseconds);
  }

  void reliableProgress() {
    _reliableAt = _clock.elapsedMicroseconds;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _socket.send(
        _codec.encode(VideoDatagramCodec.bye, _nonce, ++_helloSequence),
        _address,
        _port,
      );
    } on SocketException {
      // Closing must not recurse into fallback when the socket has failed.
    }
    _timer?.cancel();
    unawaited(_subscription.cancel());
    _socket.close();
  }
}
