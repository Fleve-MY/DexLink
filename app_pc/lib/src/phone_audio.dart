import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';

/// Validates the independently framed PCM channel before native playback.
class PhoneAudioParser {
  final List<int> _pending = [];
  bool ready = false;
  bool _failed = false;

  List<Uint8List> add(List<int> bytes) {
    if (_failed) return [];
    try {
      _pending.addAll(bytes);
      final packets = <Uint8List>[];
      var offset = 0;
      int integer(int at) =>
          ByteData.sublistView(Uint8List.fromList(_pending.sublist(at, at + 4)))
              .getUint32(0);
      if (!ready) {
        if (_pending.length < 8) return [];
        if (integer(0) == 0x444c4531) {
          final size = integer(4);
          if (size > 8192) throw const FormatException('音频错误消息过长');
          if (_pending.length < 8 + size) return [];
          throw FormatException(utf8.decode(_pending.sublist(8, 8 + size)));
        }
        if (_pending.length < 16) return [];
        if (integer(0) != 0x444c4131 ||
            integer(4) != 48000 ||
            integer(8) != 2 ||
            integer(12) != 16) {
          throw const FormatException('不支持的手机音频格式');
        }
        ready = true;
        offset = 16;
      }
      while (_pending.length - offset >= 4) {
        final size = integer(offset);
        if (size == 0 || size > 3840 || size % 4 != 0) {
          throw const FormatException('无效的音频数据包');
        }
        if (_pending.length - offset < size + 4) break;
        packets.add(
          Uint8List.fromList(_pending.sublist(offset + 4, offset + 4 + size)),
        );
        offset += size + 4;
      }
      _pending.removeRange(0, offset);
      return packets;
    } catch (_) {
      _failed = true;
      _pending.clear();
      rethrow;
    }
  }
}

class PhoneAudio {
  PhoneAudio(this.socket, this.onStatus);
  final Socket socket;
  final void Function(String) onStatus;
  static const _channel = MethodChannel('dexlink/audio');
  final _parser = PhoneAudioParser();
  StreamSubscription<Uint8List>? _subscription;
  Timer? _startupTimer;
  int? _id;
  bool _opening = false;
  bool _sending = false;
  bool _closed = false;
  bool _muted = false;
  final Queue<Uint8List> _pending = Queue<Uint8List>();

  void start() {
    _startupTimer = Timer(
      const Duration(seconds: 8),
      () => _fail('手机音频启动超时，画面继续'),
    );
    _subscription = socket.listen(
      (bytes) {
        try {
          final packets = _parser.add(bytes);
          if (_parser.ready && !_opening && _id == null) unawaited(_open());
          if (_id != null && !_muted) {
            // Preserve normal coalesced packets, but bound delayed work to 120 ms.
            for (final packet in packets) {
              if (!_sending) {
                _sending = true;
                unawaited(_push(packet));
              } else {
                if (_pending.length >= 6) _pending.removeFirst();
                _pending.addLast(packet);
              }
            }
          }
        } catch (error) {
          _fail('音频不可用：$error');
        }
      },
      onError: (Object error) => _fail('音频连接失败：$error'),
      onDone: () => _fail('手机音频已断开，画面继续'),
    );
  }

  Future<void> _open() async {
    _opening = true;
    try {
      final id = await _channel.invokeMethod<int>('create', {
        'rate': 48000,
        'channels': 2,
      });
      if (id == null) throw StateError('电脑音频输出初始化失败');
      if (_closed) {
        await _channel.invokeMethod<void>('dispose', {'id': id});
        return;
      }
      _id = id;
      _startupTimer?.cancel();
      onStatus('手机声音已接入电脑默认音频输出');
    } catch (error) {
      _fail('电脑音频输出不可用：$error');
    }
  }

  Future<void> _push(Uint8List bytes) async {
    try {
      while (!_closed && !_muted && _id != null) {
        await _channel.invokeMethod<void>('push', {'id': _id, 'data': bytes});
        if (_pending.isEmpty) break;
        bytes = _pending.removeFirst();
      }
    } catch (error) {
      _fail('电脑音频播放失败：$error');
    } finally {
      _sending = false;
    }
  }

  void setMuted(bool muted) {
    _muted = muted;
    _pending.clear();
    if (muted && _id != null) {
      unawaited(
        _channel.invokeMethod<void>('reset', {'id': _id}).catchError((
          Object error,
        ) {
          _fail('电脑音频静音失败：$error');
        }),
      );
    }
  }

  void _fail(String message) {
    if (_closed) return;
    onStatus(message);
    unawaited(dispose());
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _startupTimer?.cancel();
    _pending.clear();
    socket.destroy();
    await _subscription?.cancel();
    if (_id != null) {
      try {
        await _channel.invokeMethod<void>('dispose', {'id': _id});
      } catch (_) {
        /* Audio shutdown must not interrupt video shutdown. */
      }
    }
  }
}
