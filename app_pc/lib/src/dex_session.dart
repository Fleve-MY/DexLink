import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dex_link/dex_link.dart';

import 'session_log.dart';
import 'phone_audio.dart';
import 'adaptive_bitrate.dart';
import 'video_delivery_trend.dart';
import 'video_socket_options.dart';
import 'telemetry_freshness.dart';
import 'realtime_video.dart';
import 'native_video.dart';
import 'decoder_settings.dart';

/// A live connection to one DexLink phone.
///
/// Two TCP sockets are used: the first carries the encoded
/// video stream, the second carries control traffic in both directions. Each
/// socket starts with a single channel selector byte so the phone's bridge knows
/// where to route it.
class DexSession {
  DexSession._(this._videoSocket, this._controlSocket);

  /// A session that is not connected to anything.
  ///
  /// Only exists so widgets can hold a [RemoteInput] before the first connect
  /// succeeds; every send is a no-op.
  DexSession.placeholder()
    : _videoSocket = _NullSocket(),
      _controlSocket = _NullSocket() {
    _disposed = true;
  }

  static const int _channelVideo = 0x56; // 'V'
  static const int _channelControl = 0x43; // 'C'

  final Socket _videoSocket;
  final Socket _controlSocket;

  final StreamController<VideoEvent> _videoEvents =
      StreamController<VideoEvent>.broadcast(sync: true);
  final StreamController<DeviceMessage> _deviceMessages =
      StreamController<DeviceMessage>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();

  final VideoStreamParser _videoParser = VideoStreamParser();
  final DeviceMessageParser _deviceParser = DeviceMessageParser();

  StreamSubscription<Uint8List>? _videoSubscription;
  StreamSubscription<Uint8List>? _controlSubscription;

  bool _disposed = false;
  AdaptiveBitrate? _bitrate;
  bool _adaptiveSupported = false;
  final _feedbackClock = Stopwatch()..start();
  int? _senderSampleAt;
  bool _senderSlow = false;
  bool _senderLocalRateControl = false;
  int? _senderLoggedAt;
  int _senderDrops = 0;
  bool _senderUrgent = false, _sourceDynamic = true;
  double _receiverOldestMs = 0;
  final _delivery = VideoDeliveryTrend();
  final _telemetryFreshness = TelemetryFreshness();
  RealtimeVideoClient? _datagrams;
  CaptureEndpoint? _endpoint;
  bool _realtimeEnabled = true, _realtimeStarted = false, _usingUdp = false;
  bool _tcpWaitingKey = false;
  VideoPacket? _tcpConfig;
  int _lastVideoPts = -1;
  Map<String, Object> get videoTransportStats => {
    'videoTransport': _usingUdp ? 'realtime-udp' : 'tcp',
    ...?_datagrams?.stats,
  };
  double? sourceRefreshHz, requestedRefreshHz;

  void updateVideoPressure({required bool active, required double oldestMs}) {
    _receiverOldestMs = oldestMs;
    _datagrams?.receiverOldestMs = oldestMs;
    if (!_adaptiveSupported ||
        _deviceParser.failed ||
        _disposed ||
        _controlClosed) {
      return;
    }
    final now = _feedbackClock.elapsedMilliseconds;
    final senderSlow =
        _senderSampleAt != null && now - _senderSampleAt! < 1500 && _senderSlow;
    final urgent =
        _senderSampleAt != null &&
        now - _senderSampleAt! < 300 &&
        _senderUrgent;
    // One owner for sender congestion: a new phone reacts locally. PC queue
    // pressure still applies, but the same Wi-Fi burst must not reduce twice.
    final deliveryGrowing =
        !_senderLocalRateControl &&
        _delivery.growing(_feedbackClock.elapsedMicroseconds);
    final requested = _bitrate?.sample(
      nowMs: now,
      active: active || senderSlow || urgent || deliveryGrowing,
      oldestMs: oldestMs,
      sendingSlowly: senderSlow || deliveryGrowing,
      urgent: urgent,
      allowIncrease:
          _datagrams?.congested != true &&
          (_senderSampleAt == null ||
              (now - _senderSampleAt! < 1500 && _sourceDynamic)),
    );
    if (requested != null) {
      _log(
        '[码率] 请求 $requested，排队最老 ${oldestMs.toStringAsFixed(1)} ms，'
        '发送压力=$senderSlow 到达延迟增长=$deliveryGrowing',
      );
      send(ControlMessages.videoBitrate(requested));
    }
  }

  PhoneAudio? _audio;
  final StreamController<String> _audioStatus =
      StreamController<String>.broadcast();
  Stream<String> get audioStatus => _audioStatus.stream;
  void setAudioMuted(bool muted) => _audio?.setMuted(muted);

  /// Appends one line to the session log; see `SessionLog`.
  ///
  /// The window shows the last few sentences and forgets them when it closes,
  /// so every state transition that can matter later ("which half closed
  /// first") is also written to disk.
  static void _log(String message) {
    try {
      SessionLog.write('[会话] $message');
    } catch (_) {}
  }

  Stream<VideoEvent> get videoEvents => _videoEvents.stream;

  Stream<DeviceMessage> get deviceMessages => _deviceMessages.stream;
  bool get controlRepliesAvailable =>
      !_deviceParser.failed && !_controlClosed && !_disposed;

  /// Human readable problems (socket closed, protocol violation...).
  Stream<String> get errors => _errors.stream;

  Future<void> get closed => _closed.future;
  final Completer<void> _closed = Completer<void>();

  /// Opens both sockets.
  ///
  /// The control channel goes first on purpose. The phone shuts a session down
  /// as soon as either half hangs up ("电脑端已断开"), so if the video socket
  /// came first and the control socket then failed — port changed, Wi-Fi
  /// hiccup, the phone's Wi-Fi going to sleep — the half-open video socket
  /// would take the whole session with it and leave a black window that comes
  /// and goes. One reconnect covers both.
  ///
  /// [onHalfOpen] runs after the control socket is up but before the video
  /// socket is opened; it is where the surface starts consuming events, so
  /// the stream header cannot arrive before anyone is listening.
  static Future<DexSession> connect({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 6),
    void Function(DexSession session)? onHalfOpen,
    CaptureOptions? capture,
    bool audio = true,
    CaptureEndpoint? directEndpoint,
    bool realtime = true,
  }) async {
    if (capture != null &&
        directEndpoint == null &&
        capture.features & kCapturePreferHevc != 0 &&
        (!Platform.isWindows ||
            DecoderSettings.read() == DecoderMode.software ||
            !await NativeVideoDecoder.supportsHevc(capture.maxSize))) {
      capture = CaptureOptions(
        fps: capture.fps,
        maxSize: capture.maxSize,
        bitrate: capture.bitrate,
        features: capture.features & ~kCapturePreferHevc,
      );
    }
    final endpoint =
        directEndpoint ??
        (capture == null
            ? null
            : await configure(host, port, capture, timeout: timeout));
    final streamPort = endpoint?.port ?? port;
    Socket? audioSocket;
    if (audio && endpoint?.audio == true) {
      try {
        audioSocket = await Socket.connect(host, streamPort, timeout: timeout);
        audioSocket.setOption(SocketOption.tcpNoDelay, true);
        audioSocket.add(endpoint!.header(0x41));
      } catch (error) {
        _log('音频通道连接失败，继续连接画面：$error');
      }
    }
    Socket control;
    try {
      control = await Socket.connect(host, streamPort, timeout: timeout);
    } catch (_) {
      audioSocket?.destroy();
      rethrow;
    }
    control.setOption(SocketOption.tcpNoDelay, true);
    control.add(endpoint?.header(_channelControl) ?? <int>[_channelControl]);
    _log('控制通道已连上 $host:$streamPort${endpoint == null ? '' : '（直接采集通道）'}');

    Socket? video;
    try {
      video = await Socket.connect(host, streamPort, timeout: timeout);
      video.setOption(SocketOption.tcpNoDelay, true);
      final receiveBuffer = configureVideoReceiveBuffer(video);
      _log('视频接收缓冲 ${receiveBuffer ?? "系统默认"} 字节');
      video.add(endpoint?.header(_channelVideo) ?? <int>[_channelVideo]);
      _log('视频通道已连上');
    } catch (error) {
      audioSocket?.destroy();
      _log('视频通道连接失败：$error');
      // Never leave a dangling control socket: the phone would treat the
      // hang-up as "the PC left" and tear down the projection.
      try {
        await control.close();
      } catch (_) {}
      rethrow;
    }

    final session = DexSession._(video, control);
    session._endpoint = endpoint;
    session._realtimeEnabled = realtime;
    if (capture != null && capture.features & kCaptureAdaptiveBitrate != 0) {
      session._bitrate = AdaptiveBitrate(capture.bitrate);
    }
    session._listen();
    onHalfOpen?.call(session);
    if (audioSocket != null) {
      session._audio = PhoneAudio(audioSocket, (status) {
        _log('[音频] $status');
        if (!session._audioStatus.isClosed) session._audioStatus.add(status);
      })..start();
    } else if (audio) {
      scheduleMicrotask(() {
        if (!session._audioStatus.isClosed) {
          session._audioStatus.add('当前手机通道不支持声音转发或连接失败');
        }
      });
    }
    return session;
  }

  static Future<CaptureEndpoint?> configure(
    String host,
    int port,
    CaptureOptions options, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final request = options.request();
    final socket = await Socket.connect(host, port, timeout: timeout);
    try {
      socket.add(request);
      final reply = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout);
      final result = jsonDecode(reply) as Map;
      if (result['ok'] != true) {
        if (options.features & kCapturePreferHevc != 0) {
          socket.destroy();
          _log('手机未接受HEVC协商，改用兼容H.264设置');
          return await configure(
            host,
            port,
            CaptureOptions(
              fps: options.fps,
              maxSize: options.maxSize,
              bitrate: options.bitrate,
              features: options.features & ~kCapturePreferHevc,
            ),
            timeout: timeout,
          );
        }
        throw StateError(result['error'] ?? '手机拒绝投屏设置');
      }
      final endpoint = CaptureEndpoint.parse(result);
      _log(
        '采集设置已确认 ${options.fps == 0 ? "无帧率上限" : "${options.fps} FPS"} / 长边 ${options.maxSize} / ${options.bitrate ~/ 1000000} Mbps',
      );
      return endpoint;
    } on StateError catch (error) {
      throw StateError('无法应用投屏设置，请确认手机端已更新并重新开始投屏：$error');
    } finally {
      socket.destroy();
    }
  }

  void _listen() {
    var videoBytes = 0;
    var firstByte = -1;
    _videoSubscription = _videoSocket.listen(
      (chunk) {
        // A socket can deliver one last chunk after the window has been closed;
        // adding to a closed controller throws "Cannot add new events".
        if (_disposed) return;
        if (firstByte < 0 && chunk.isNotEmpty) {
          firstByte = chunk.first;
          _log(
            '视频通道收到第一批 ${chunk.length} 字节，首字节 0x'
            '${firstByte.toRadixString(16)}',
          );
        }
        videoBytes += chunk.length;
        try {
          for (final event in _videoParser.parse(chunk)) {
            if (event is VideoStreamStarted) {
              _adaptiveSupported = event.info.adaptiveBitrate;
              if (event.info.realtimeVideo &&
                  _realtimeEnabled &&
                  _endpoint != null) {
                unawaited(_startRealtime());
              }
            }
            if (event is VideoFrameReceived) {
              final packet = event.packet;
              if (packet.config) {
                _tcpConfig = packet;
                if (_usingUdp || _tcpWaitingKey) continue;
              } else {
                if (packet.pts <= _lastVideoPts) continue;
                if (_usingUdp || _tcpWaitingKey) {
                  if (!packet.keyFrame) continue;
                  if (_usingUdp) _datagrams?.fallback('phone-resumed-tcp');
                  _usingUdp = false;
                  _tcpWaitingKey = false;
                  if (_tcpConfig != null) {
                    _videoEvents.add(VideoFrameReceived(_tcpConfig!));
                  }
                }
                _lastVideoPts = packet.pts;
                _datagrams?.reliableProgress();
                _delivery.add(_feedbackClock.elapsedMicroseconds, packet.pts);
              }
            }
            if (event is VideoStreamError) {
              _log('视频流错误：${event.message}');
              _errors.add(event.message);
            }
            _videoEvents.add(event);
          }
        } catch (error) {
          _log('视频流解析失败：$error（已收 $videoBytes 字节）');
          if (!_disposed) _errors.add('视频流解析失败: $error');
        }
      },
      onError: (Object error) {
        _log('视频通道错误：$error（已收 $videoBytes 字节）');
        if (!_disposed) _errors.add('视频通道错误: $error');
      },
      onDone: () {
        _log('视频通道 EOF，共收到 $videoBytes 字节');
        if (videoBytes == 0 && firstByte < 0) {
          // The socket was accepted and closed without a single byte: the phone
          // never started encoding. That is a phone-side refusal, not a slow
          // start, and the log line above is the only way to tell them apart.
          if (!_errors.isClosed) {
            _errors.add(
              '手机接受了画面连接，但一个字节都没发就关掉了。'
              '多半是录屏授权失效或编码器启动失败——请在手机上重新点一次「开始镜像」。',
            );
          }
        }
        _halfClosed(video: true);
      },
      cancelOnError: false,
    );

    _controlSubscription = _controlSocket.listen(
      (chunk) {
        if (_disposed) return;
        try {
          final parsed = _deviceParser.parse(chunk).toList();
          CaptureTelemetry? latest;
          for (final message in parsed) {
            if (message is CaptureTelemetry) latest = message;
          }
          for (final message in parsed) {
            if (message is CaptureTelemetry && identical(message, latest)) {
              final data = message.data;
              sourceRefreshHz = (data['sourceRefreshHz'] as num?)?.toDouble();
              requestedRefreshHz = (data['requestedRefreshHz'] as num?)
                  ?.toDouble();
              final now = _feedbackClock.elapsedMilliseconds;
              if (!_telemetryFreshness.accept(
                now,
                (data['sampleTimeMs'] as num?)?.toInt(),
              )) {
                _deviceMessages.add(message);
                continue;
              }
              final localRate = data['senderLocalRateControl'] == true;
              _senderLocalRateControl = localRate;
              if (localRate) {
                _bitrate?.observeSenderBitrate(
                  (data['bitrate'] as num?)?.toInt() ?? 0,
                  now,
                );
              }
              if (_senderLoggedAt == null || now - _senderLoggedAt! >= 5000) {
                _senderLoggedAt = now;
                _log('[手机采集] ${jsonEncode(data)}');
              }
              final window = (data['windowMs'] as num?)?.toDouble() ?? 0;
              final sendMs = (data['sendMs'] as num?)?.toDouble() ?? 0;
              final maxSendMs = (data['maxSendMs'] as num?)?.toDouble() ?? 0;
              final frames =
                  (data['sourceFrames'] as num?)?.toInt() ??
                  (data['frames'] as num?)?.toInt() ??
                  0;
              final queueMs = (data['senderQueueMs'] as num?)?.toDouble() ?? 0;
              final writingMs =
                  (data['senderWritingMs'] as num?)?.toDouble() ?? 0;
              final drops = (data['senderDropped'] as num?)?.toInt() ?? 0;
              final peakQueue =
                  (data['senderPeakQueueMs'] as num?)?.toDouble() ?? queueMs;
              final peakWriting =
                  (data['senderPeakWritingMs'] as num?)?.toDouble() ??
                  writingMs;
              _senderSampleAt = now;
              // Separate encoder output from network output; a blocked write
              // must remain visible even when zero frames finish sending.
              _senderSlow =
                  !localRate &&
                  (queueMs >= 33 ||
                      peakQueue >= 50 ||
                      writingMs >= 50 ||
                      peakWriting >= 66 ||
                      drops > _senderDrops ||
                      (window >= 80 &&
                          frames * 1000 / window >= 20 &&
                          sendMs / window >= .35 &&
                          maxSendMs >= 50));
              _senderUrgent =
                  !localRate && (drops > _senderDrops || writingMs >= 100);
              _sourceDynamic = window > 0 && frames * 1000 / window >= 20;
              _senderDrops = drops;
              // Feed pressure immediately; UI polling must not delay a sender
              // stall or a short peak that cleared before the next UI tick.
              updateVideoPressure(
                active: frames > 0,
                oldestMs: _receiverOldestMs,
              );
            } else if (message is VideoBitrateResult) {
              _log('[码率] 手机回执 ${jsonEncode(message.data)}');
              _bitrate?.acknowledge(
                success: message.data['ok'] == true,
                bitrate: (message.data['bitrate'] as num?)?.toInt() ?? 0,
              );
            }
            _deviceMessages.add(message);
          }
        } catch (error) {
          _log('控制回执解析已停止：$error');
          if (!_disposed) _errors.add('手机控制回执版本不兼容，请更新两端并重连；画面与输入仍可使用：$error');
        }
      },
      onError: (Object error) {
        if (!_disposed) _errors.add('控制通道错误: $error');
      },
      onDone: () => _halfClosed(video: false),
      cancelOnError: false,
    );
  }

  Future<void> _startRealtime() async {
    if (_realtimeStarted || _disposed) return;
    _realtimeStarted = true;
    try {
      final client = await RealtimeVideoClient.connect(
        address: _videoSocket.remoteAddress,
        port: _endpoint!.port,
        token: _endpoint!.token,
        onUnit: (packets) {
          if (_disposed || packets.last.pts <= _lastVideoPts) return;
          if (!_usingUdp && !packets.last.keyFrame) {
            // TCP may have advanced past the first UDP IDR while recovering.
            // Its predictive tail cannot use the TCP decoder reference chain.
            _datagrams?.requireKeyframe();
            return;
          }
          if (!_usingUdp) _log('视频已切换为有期限修复的实时无线通道');
          _usingUdp = true;
          _tcpWaitingKey = true;
          for (final packet in packets) {
            if (!packet.config) {
              _lastVideoPts = packet.pts;
              _delivery.add(_feedbackClock.elapsedMicroseconds, packet.pts);
            }
            _videoEvents.add(VideoFrameReceived(packet));
          }
        },
        onFallback: (reason) {
          if (_disposed) return;
          _log('实时视频通道回退TCP：$reason');
          if (_usingUdp) {
            _usingUdp = false;
            _tcpWaitingKey = true;
            send(ControlMessages.resetVideo());
          }
        },
      );
      if (_disposed) {
        client.close();
      } else {
        _datagrams = client;
      }
    } catch (error) {
      _log('实时通道未启用，继续TCP：$error');
    }
  }

  bool _controlClosed = false;
  bool _videoClosed = false;

  /// True when the picture stopped but the phone is still in a session (see
  /// [_halfClosed]); the user can reconnect without touching the phone.
  bool get videoLost => _videoLost;
  bool _videoLost = false;

  /// The video half hung up.
  ///
  /// The phone only ends a session for real when the PC goes away, and it
  /// reports that by closing *both* sockets. Losing the video socket while the
  /// control socket is still alive means something failed on the way (a Wi-Fi
  /// roam, the phone's Wi-Fi sleeping, a dropped packet storm), not that the
  /// user wants to stop: keep the control half, say so in a sentence, and let
  /// the window offer "重新连接" instead of turning this into a dead window.
  void _halfClosed({required bool video}) {
    _log(
      'half-closed: video=$video controlClosed=$_controlClosed '
      'videoClosed=$_videoClosed',
    );
    if (_disposed) return;
    if (video) {
      _videoClosed = true;
      if (_controlClosed) {
        _shutdown('会话已结束（手机那边停止了投屏）');
        return;
      }
      _videoLost = true;
      if (!_errors.isClosed) {
        _errors.add('画面通道已断开（手机仍在会话里）。点顶栏的「重新连接」即可恢复画面。');
      }
      // Tell every listener the stream is over *now*: the socket is finished,
      // and a listener that keeps waiting will wait forever (which is how the
      // window decides whether it ever had a picture).
      if (!_videoEvents.isClosed) unawaited(_videoEvents.close());
      try {
        _videoSocket.destroy();
      } catch (_) {}
      return;
    }
    if (_controlClosed) return;
    _controlClosed = true;
    if (_videoClosed) {
      _shutdown('会话已结束（手机那边停止了投屏）');
      return;
    }
    if (!_errors.isClosed) {
      _errors.add('控制通道已断开：画面还在，但点击、键盘和粘贴暂时用不了，重新连接即可恢复。');
    }
  }

  /// Sends a pre-encoded control message (see `ControlMessages`).
  void send(Uint8List message) {
    if (_disposed || _controlClosed) return;

    try {
      _controlSocket.add(message);
    } catch (error) {
      _errors.add('发送控制指令失败: $error');
    }
  }

  void _shutdown(String reason) {
    if (_disposed) return;
    if (!_errors.isClosed) _errors.add(reason);
    // The socket closures below will bring us back here; whoever awaits the
    // first call gets the same future as everyone else.
    _disposal ??= _dispose();
  }

  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _datagrams?.close();
    await _audio?.dispose();
    await _audioStatus.close();
    // Sockets first: an EOF that is already queued must run `_halfClosed`
    // while nothing below has been torn down yet.
    await _videoSubscription?.cancel();
    await _controlSubscription?.cancel();
    try {
      await _videoSocket.close();
    } catch (_) {}
    try {
      await _controlSocket.close();
    } catch (_) {}
    await _videoEvents.close();
    await _deviceMessages.close();
    await _errors.close();
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// Optional shell-owned endpoint returned by capture negotiation.
class CaptureEndpoint {
  CaptureEndpoint._(this.port, this.token, this.audio);
  final int port;
  final String token;
  final bool audio;

  static CaptureEndpoint? parse(Map result) {
    final port = result['streamPort'];
    final token = result['streamToken'];
    if (port == null && token == null) return null;
    if (port is! int ||
        port < 1 ||
        port > 65535 ||
        token is! String ||
        !RegExp(r'^[a-zA-Z0-9-]{32,128}$').hasMatch(token)) {
      throw StateError('手机返回了无效的直接采集通道');
    }
    return CaptureEndpoint._(port, token, result['audio'] == true);
  }

  List<int> header(int channel) {
    final bytes = ascii.encode(token);
    return [bytes.length >> 8, bytes.length & 255, ...bytes, channel];
  }
}

/// Stands in for a socket in [DexSession.placeholder]; never used.
class _NullSocket implements Socket {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
