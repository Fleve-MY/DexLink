import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';

import 'decoder_settings.dart';
import 'latency_samples.dart';

/// Only compressed access units cross this channel. Decoded pixels stay in
/// Windows and are uploaded by Flutter's texture registrar.
class NativeVideoDecoder {
  NativeVideoDecoder._(this._sessionId) : textureId = _sessionId;
  static const _channel = MethodChannel('dexlink/video');
  final int _sessionId;
  int textureId;
  bool _closed = false;
  bool _paused = false;
  Object? _pushError;
  final _pending =
      Queue<({Uint8List data, int pts, bool key, int enqueuedUs})>();
  final _clock = Stopwatch()..start();
  final _dwell = LatencySamples();
  final _dropDwell = LatencySamples();
  final _submit = LatencySamples();
  final _trace = Queue<Map<String, Object>>();
  int _clearDrops = 0, _gateDrops = 0, _clears = 0;
  int _pendingBytes = 0;
  int _queued = 0;
  int _dropped = 0;
  bool _sending = false;
  bool _waitingKey = false;
  bool _needKeyframe = false;
  static final _hevcProbes = <int, Future<bool>>{};
  static Future<bool> supportsHevc(int maxSize) =>
      _hevcProbes.putIfAbsent(maxSize, () async {
        try {
          final capabilities = await _channel.invokeMapMethod<String, dynamic>(
            'capabilities',
            {'maxSize': maxSize},
          );
          return capabilities?['hevcHardware'] == true;
        } catch (_) {
          return false;
        }
      });

  static Future<NativeVideoDecoder> create(
    int width,
    int height,
    DecoderMode mode, {
    int fps = 60,
    bool gpu = true,
    int codecId = 0x68323634,
  }) async {
    final id = await _channel.invokeMethod<int>('create', {
      'width': width,
      'height': height,
      'mode': mode.name,
      'fps': fps,
      'gpu': gpu,
      'codec': codecId,
    });
    if (id == null || id < 0) throw StateError('视频纹理创建失败');
    return NativeVideoDecoder._(id);
  }

  void push(Uint8List data, int pts, bool key) {
    if (_closed || _paused || _pushError != null) return;
    // An IDR starts an independent prediction chain. Replace a stale queued
    // chain only at this boundary, never drop arbitrary reference frames.
    final staleKey =
        key &&
        _pending.isNotEmpty &&
        _clock.elapsedMicroseconds - _pending.first.enqueuedUs >= 80000;
    if (staleKey ||
        _pending.length >= 64 ||
        _pendingBytes + data.length > 8 * 1024 * 1024) {
      _dropped += _pending.length;
      _clearDrops += _pending.length;
      _clears++;
      final now = _clock.elapsedMicroseconds;
      for (final packet in _pending) {
        _dropDwell.add(now, now - packet.enqueuedUs);
      }
      _pending.clear();
      _pendingBytes = 0;
      _waitingKey = _needKeyframe = true;
    }
    if (_waitingKey && !key) {
      _dropped++;
      _gateDrops++;
      return;
    }
    if (key) _waitingKey = _needKeyframe = false;
    _pending.add((
      data: data,
      pts: pts,
      key: key,
      enqueuedUs: _clock.elapsedMicroseconds,
    ));
    _pendingBytes += data.length;
    if (!_sending) {
      _sending = true;
      scheduleMicrotask(_sendPending);
    }
  }

  Future<void> _sendPending() async {
    try {
      while (!_closed && !_paused && _pending.isNotEmpty) {
        // One platform call in flight. Let the native worker drain before
        // sending another burst; compressed reference frames remain ordered.
        if (_queued > 4) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          if (_closed || _paused) break;
          _queued =
              await _channel.invokeMethod<int>('queued', {'id': _sessionId}) ??
              0;
          continue;
        }
        final batch = <Map<String, Object>>[];
        while (_pending.isNotEmpty && batch.length < 4) {
          final packet = _pending.removeFirst();
          final now = _clock.elapsedMicroseconds;
          _dwell.add(now, now - packet.enqueuedUs);
          _trace.add({
            'pts': packet.pts,
            'dartDwellMs': (now - packet.enqueuedUs) / 1000,
          });
          if (_trace.length > 256) _trace.removeFirst();
          _pendingBytes -= packet.data.length;
          batch.add({
            'data': packet.data,
            'pts': packet.pts,
            'key': packet.key,
          });
        }
        final submitAt = _clock.elapsedMicroseconds;
        _queued =
            await _channel.invokeMethod<int>('pushBatch', {
              'id': _sessionId,
              'packets': batch,
            }) ??
            0;
        final submittedAt = _clock.elapsedMicroseconds;
        _submit.add(submittedAt, submittedAt - submitAt);
      }
    } catch (error) {
      if (!_closed && !_paused) _pushError = error;
    } finally {
      _sending = false;
    }
  }

  Future<Map<dynamic, dynamic>> stats({bool trace = false}) async {
    if (_closed) return const {};
    if (_pushError != null) throw StateError('原生视频输入失败: $_pushError');
    final stats =
        await _channel.invokeMapMethod<dynamic, dynamic>('stats', {
          'id': _sessionId,
          'trace': trace,
        }) ??
        const {};
    textureId = (stats['textureId'] as num?)?.toInt() ?? textureId;
    stats['needKeyframe'] = stats['needKeyframe'] == true || _needKeyframe;
    if (_pending.isNotEmpty &&
        _clock.elapsedMicroseconds - _pending.first.enqueuedUs >= 120000) {
      stats['needKeyframe'] = true;
    }
    stats['queued'] =
        ((stats['queued'] as num?)?.toInt() ?? 0) + _pending.length;
    stats['dropped'] = ((stats['dropped'] as num?)?.toInt() ?? 0) + _dropped;
    final now = _clock.elapsedMicroseconds;
    stats['dartDwell'] = _dwell.snapshot(now);
    stats['dartDropDwell'] = _dropDwell.snapshot(now);
    stats['submitCall'] = _submit.snapshot(now);
    stats['dartQueued'] = _pending.length;
    stats['dartOldestMs'] = _pending.isEmpty
        ? 0.0
        : (now - _pending.first.enqueuedUs) / 1000;
    stats['dartClearDrops'] = _clearDrops;
    stats['dartGateDrops'] = _gateDrops;
    stats['dartClears'] = _clears;
    if (trace) stats['dartTrace'] = _trace.toList();
    return stats;
  }

  Future<void> pause() async {
    if (_closed || _paused) return;
    _paused = true;
    _pending.clear();
    _pendingBytes = 0;
    await _channel.invokeMethod<void>('pause', {'id': _sessionId});
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    _pendingBytes = 0;
    await _channel.invokeMethod<void>('dispose', {'id': _sessionId});
  }
}
