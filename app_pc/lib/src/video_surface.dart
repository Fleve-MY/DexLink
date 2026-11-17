import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dex_link/dex_link.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'native_video.dart';
import 'decoder_settings.dart';
import 'session_log.dart';
import 'ts_muxer.dart';
import 'latency_samples.dart';
import 'recent_video_gop.dart';

/// The surface of the currently connected session, used by `--fake-phone`.
PhoneVideoSurface? debugActiveSurface;

/// Decodes the phone's H.264 stream and draws it with Flutter itself.
class PhoneVideoSurface {
  PhoneVideoSurface({
    this.decoderMode = DecoderMode.auto,
    this.trackFlutterFrames = false,
  }) {
    if (trackFlutterFrames) {
      SchedulerBinding.instance.addTimingsCallback(_frameTimings);
    }
  }
  final bool trackFlutterFrames;
  final _timingClock = Stopwatch()..start();
  final _buildTiming = LatencySamples(), _rasterTiming = LatencySamples();
  void _frameTimings(List<ui.FrameTiming> timings) {
    if (_disposed || _paused) return;
    final now = _timingClock.elapsedMicroseconds;
    for (final timing in timings) {
      _buildTiming.add(now, timing.buildDuration.inMicroseconds);
      _rasterTiming.add(now, timing.rasterDuration.inMicroseconds);
    }
  }

  DecoderMode decoderMode;
  VoidCallback? onNeedKeyframe;
  Timer? _keyRequestCooldown;
  int _keyRequests = 0;
  String _pipelineTiming = '';
  double _oldestQueueMs = 0;
  double get oldestQueueMs => _oldestQueueMs;

  void _requestKeyframe() {
    if (_disposed || _paused || onNeedKeyframe == null) return;
    if (_keyRequestCooldown?.isActive == true) return;
    _keyRequestCooldown = Timer(const Duration(milliseconds: 300), () {});
    _keyRequests++;
    onNeedKeyframe!.call();
  }

  int _nativeSkipped = 0;
  String _nativeBackend = 'starting';
  String _fallbackReason = '';
  bool _forceSoftware = false;
  String get decoderLabel => switch (_nativeBackend) {
    'hardware' => '硬件解码',
    'software' => '软件解码',
    'failed' => '解码失败',
    _ => _nativeUnavailable ? '软件解码（兼容）' : '等待解码',
  };
  String get fallbackReason => _fallbackReason;
  final ValueNotifier<VideoStreamInfo?> info = ValueNotifier<VideoStreamInfo?>(
    null,
  );
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);
  final ValueNotifier<ui.Image?> frame = ValueNotifier<ui.Image?>(null);
  final ValueNotifier<int> videoRevision = ValueNotifier<int>(0);
  NativeVideoDecoder? _native;
  Future<Map<dynamic, dynamic>> diagnosticTrace() async =>
      await _native?.stats(trace: true) ?? const {};
  Timer? _nativeTimer;
  bool _nativeStarting = false;
  bool _nativeUnavailable = false;
  bool _nativePolling = false;
  int _nativeWidth = 0;
  int _nativeHeight = 0;
  int _nativeQueued = 0;
  int _nativePresented = 0;
  double _nativeDecodeMs = 0;
  double _nativeLocalMs = 0;
  bool get hasPicture =>
      frame.value != null || (_native != null && _rendered > 0);
  Size? get pictureSize => _native != null && _nativeWidth > 0
      ? Size(_nativeWidth.toDouble(), _nativeHeight.toDouble())
      : frame.value == null
      ? null
      : Size(frame.value!.width.toDouble(), frame.value!.height.toDouble());
  int get presentedFrames => _native != null ? _nativePresented : _rendered;

  final TsMuxer _muxer = TsMuxer();
  final List<Uint8List> _pending = <Uint8List>[];
  final _lastGop = RecentVideoGop();
  bool _nativeWaitingKey = true;
  final List<int> _jpegBuffer = <int>[];
  int _scanPos = 0;

  Uint8List? _spsPps;
  bool _needsConfigPrefix = true;

  /// Frames handed to Flutter are kept around for a few generations before
  /// being disposed: the raster thread may still be painting the previous one,
  /// and disposing it under its feet makes the whole surface go away.
  final List<ui.Image> _live = <ui.Image>[];
  static const int _liveLimit = 6;

  StreamSubscription<VideoEvent>? _events;
  StreamSubscription<List<int>>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  Process? _ffmpeg;
  ServerSocket? _server;
  Socket? _client;
  Timer? _watchdog;

  bool _disposed = false;
  bool _decoding = false;
  Uint8List? _latestJpeg;
  bool _feeding = false;
  bool _waitingForKeyFrame = false;
  bool _started = false;
  int _restarts = 0;
  int _generation = 0;
  String? _ffmpegPath;
  static String? _cachedFfmpegPath;

  /// Set by [pause] when the session said the picture is gone for good.
  bool _paused = false;

  /// True once [pause] ran and nothing has restarted the pipeline since.
  bool get isPaused => _paused;
  bool _visible = true;

  /// Minimized app streams deliberately stop producing frames. Keep the
  /// decoder/reference state, but suspend polling and stall recovery.
  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _silentTicks = 0;
    _checkedFrames = _frames;
    if (value) _requestKeyframe();
  }

  String _stage = 'created';
  String _lastWarning = '';
  int _frames = 0;
  int _receivedPictures = 0;
  int get receivedPictures => _receivedPictures;
  int _bytes = 0;
  int _rendered = 0;
  int _outBytes = 0;
  bool _sawJpegBytes = false;
  String? _watchdogMessage;
  int _checkedFrames = 0;
  int _silentTicks = 0;
  bool _captureStalled = false;
  DateTime? _startedAt;
  Timer? _navigationTimer;

  /// Ask for a picture after the Home animation, not just its first frame.
  void expectNavigationFrame() {
    _navigationTimer?.cancel();
    _navigationTimer = Timer(const Duration(milliseconds: 400), () {
      if (_disposed || _paused) return;
      final rendered = _rendered;
      SessionLog.write('[导航] 请求切换后的完整画面：$debugState');
      _requestKeyframe();
      _navigationTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (_disposed || _paused) {
          timer.cancel();
          return;
        }
        if (_rendered > rendered) {
          SessionLog.write('[导航] 切换后画面已更新：$debugState');
          timer.cancel();
        } else if (timer.tick < 3) {
          SessionLog.write('[导航] 画面未更新，再次请求完整画面：$debugState');
          _requestKeyframe();
        } else {
          timer.cancel();
          lastError.value = '手机已执行导航，但切换后的画面尚未恢复，请重新连接投屏';
          SessionLog.write('[导航] 切换后画面超时：$debugState');
        }
      });
    });
  }

  /// Keeps the CPU cost bounded; the phone may stream at 60 fps and 2K.
  static const int _maxDimension = 1600;

  /// A single JPEG that big means the pipeline is stalling.
  static const int _maxJpegBytes = 8 * 1024 * 1024;

  Future<void> attach(Stream<VideoEvent> events) async {
    _stage = 'subscribing';
    _startedAt ??= DateTime.now();
    _detached = false;
    final previous = _events;
    _events = events.listen(_onEvent, onDone: () => _detached = true);
    await previous?.cancel();
    _watchdog ??= Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  DateTime? get startedAt => _startedAt;

  /// Stops decoding without tearing anything down: the session is gone but the
  /// widget is still on screen, so the last frame stays as a still image.
  void pause() {
    _navigationTimer?.cancel();
    _generation++;
    _paused = true;
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_events?.cancel());
    _events = null;
    _nativeTimer?.cancel();
    _nativeTimer = null;
    unawaited(_native?.pause());
    _ffmpeg?.kill();
    _ffmpeg = null;
    _client?.destroy();
    _client = null;
    unawaited(_stdout?.cancel());
    unawaited(_stderr?.cancel());
    _pending.clear();
    _lastGop.clear();
    _spsPps = null;
    _needsConfigPrefix = true;
    _jpegBuffer.clear();
    _scanPos = 0;
    _latestJpeg = null;
    _waitingForKeyFrame = false;
    _stage = 'paused';
  }

  /// Rewinds every counter so this surface can decode a fresh session, then
  /// subscribes to [events] (usually after `pause()`).
  Future<void> restart(Stream<VideoEvent> events) async {
    if (_disposed) return;
    pause();
    final oldNative = _native;
    _native = null;
    await oldNative?.dispose();
    if (_disposed) return;
    _nativeStarting = false;
    _nativeUnavailable = false;
    _keyRequestCooldown?.cancel();
    _keyRequests = 0;
    _pipelineTiming = '';
    _oldestQueueMs = 0;
    _buildTiming.clear();
    _rasterTiming.clear();
    _nativeSkipped = 0;
    _nativeBackend = 'starting';
    _fallbackReason = '';
    _forceSoftware = false;
    _nativeWidth = 0;
    _nativeHeight = 0;
    videoRevision.value++;
    _paused = false;
    _detached = false;
    _muxer.reset();
    _lastGop.clear();
    _spsPps = null;
    _needsConfigPrefix = true;
    _pending.clear();
    _jpegBuffer.clear();
    _scanPos = 0;
    _frames = 0;
    _bytes = 0;
    _rendered = 0;
    _outBytes = 0;
    _sawJpegBytes = false;
    _restarts = 0;
    _lastPts = -1;
    _started = false;
    _watchdogMessage = null;
    _lastWarning = '';
    _checkedFrames = 0;
    _receivedPictures = 0;
    _silentTicks = 0;
    _captureStalled = false;
    _startedAt = null;
    info.value = null;
    lastError.value = null;
    await attach(events);
  }

  int get renderedFrames => _rendered;
  int get receivedFrames => _frames;
  int get decodedBytes => _outBytes;
  VideoStreamInfo? get streamInfo => info.value;

  /// Native H.264 handles SPS size changes in place. The JPEG compatibility
  /// encoder has a fixed output size, so restart only that local pipeline.
  void resizeVideo(int width, int height) {
    final previous = info.value;
    if (_disposed ||
        _paused ||
        previous == null ||
        (previous.width == width && previous.height == height)) {
      return;
    }
    final next = VideoStreamInfo(
      deviceName: previous.deviceName,
      codecId: previous.codecId,
      width: width,
      height: height,
      clientResize: previous.clientResize,
      frameRate: previous.frameRate,
      unlimited: previous.unlimited,
      dynamicSize: previous.dynamicSize,
      panelPower: previous.panelPower,
      desktopControl: previous.desktopControl,
      adaptiveBitrate: previous.adaptiveBitrate,
      appWindows: previous.appWindows,
    );
    info.value = next;
    if (_native != null || _nativeStarting) return;
    _generation++;
    final old = _ffmpeg;
    _ffmpeg = null;
    old?.kill();
    _client?.destroy();
    _client = null;
    unawaited(_stdout?.cancel());
    unawaited(_stderr?.cancel());
    _pending.clear();
    _queuedBytes = 0;
    _lastGop.clear();
    _jpegBuffer.clear();
    _scanPos = 0;
    _latestJpeg = null;
    _waitingForKeyFrame = true;
    _needsConfigPrefix = true;
    _muxer.reset();
    _requestKeyframe();
    unawaited(_startDecoder(next));
  }

  /// One sentence for the user: what the pipeline is doing right now.
  String get status {
    if (lastError.value != null) return lastError.value!;
    if (!_started) {
      if (_detached) return '连接已断开，还没有收到画面参数';
      return '已连接，等待手机的画面参数…';
    }
    if (_frames == 0) return '画面参数已收到，等待第一帧数据…';
    if (_rendered == 0) return '收到 $_frames 帧数据，正在解码…';
    return '画面正常 · 已渲染 $_rendered 帧';
  }

  /// Set when the event stream ends, i.e. the video socket closed.
  bool _detached = false;

  void _onEvent(VideoEvent event) {
    if (_disposed) return;
    switch (event) {
      case VideoStreamStarted(:final info):
        _muxer.hevc = info.isH265;
        this.info.value = info;
        _started = true;
        _stage = 'stream-meta';
        _startDecoder(info);
      case VideoStreamError(:final message):
        _stage = 'stream-error';
        _watchdogMessage = message;
        lastError.value = message;
      case VideoFrameReceived(:final packet):
        if (packet.data.isEmpty) break;
        _silentTicks = 0;
        if (_captureStalled) {
          _captureStalled = false;
          _watchdogMessage = null;
          lastError.value = null;
          SessionLog.write('[采集] 视频数据已恢复');
        }
        _frames++;
        _bytes += packet.data.length;
        if (packet.config) {
          // Keep raw SPS/PPS bytes to prepend directly into the next keyframe
          // PES packet so continuity counters and PTS never jump.
          _spsPps = Uint8List.fromList(packet.data);
          _needsConfigPrefix = true;
          _lastGop.clear();
          _nativeWaitingKey = true;
          _dropped += _pending.length;
          _pending.clear();
          _queuedBytes = 0;
          _waitingForKeyFrame = true;
          break;
        }
        final isKey = packet.keyFrame;
        _receivedPictures++;
        _lastGop.add(packet);
        if (_native != null) {
          _feedNative(packet);
          break;
        }
        _feedPacket(packet, isKey: isKey);
    }
  }

  int _monotonicPts(int phonePts) {
    // Repair ordering only; do not impose a synthetic 60 FPS timeline.
    final next = phonePts > _lastPts ? phonePts : _lastPts + 1;
    _lastPts = next;
    return next;
  }

  int _lastPts = -1;

  void _feedPacket(VideoPacket packet, {required bool isKey}) {
    if (_client == null) return; // Startup replays _lastGop freshly muxed.
    if (_pending.length >= 20 ||
        _queuedBytes + packet.data.length > _maxQueuedBytes) {
      _dropped += _pending.length;
      _pending.clear();
      _queuedBytes = 0;
      _waitingForKeyFrame = true;
      if (!isKey) _requestKeyframe();
    }
    if (_waitingForKeyFrame) {
      if (!isKey) {
        _dropped++;
        return;
      }
      _waitingForKeyFrame = false;
      _needsConfigPrefix = true;
    }
    final prefix = (isKey || _needsConfigPrefix) ? _spsPps : null;
    final ts = _muxer.accessUnit(
      packet.data,
      _monotonicPts(packet.pts),
      configPrefix: prefix,
    );
    if (ts.isEmpty) return;
    if (prefix != null) _needsConfigPrefix = false;
    _pending.add(ts);
    _queuedBytes += ts.length;
    unawaited(_flushPending());
  }

  Future<void> _flushPending() async {
    if (_feeding) return;
    final client = _client;
    if (client == null) return;
    _feeding = true;
    try {
      while (!_disposed &&
          !_paused &&
          identical(client, _client) &&
          _pending.isNotEmpty) {
        final batch = List<Uint8List>.of(_pending);
        _pending.clear();
        _queuedBytes = 0;
        for (final chunk in batch) {
          client.add(chunk);
        }
        await client.flush();
      }
    } catch (error) {
      if (!_disposed && !_paused && identical(client, _client)) {
        lastError.value = '送入解码器失败: $error';
        _stage = 'feed-failed';
        _client = null;
      }
    } finally {
      _feeding = false;
      if (_pending.isNotEmpty && _client != null && !_disposed && !_paused) {
        unawaited(_flushPending());
      }
    }
  }

  int _queuedBytes = 0;
  int _dropped = 0;

  static const int _maxQueuedBytes = 1024 * 1024;

  void _feedNative(VideoPacket packet) {
    if (_nativeWaitingKey && !packet.keyFrame) {
      _requestKeyframe();
      return;
    }
    if (packet.keyFrame) _nativeWaitingKey = false;
    final prefix = packet.keyFrame ? _spsPps : null;
    final bytes = prefix == null
        ? packet.data
        : (BytesBuilder(copy: false)
                ..add(prefix)
                ..add(packet.data))
              .takeBytes();
    _native?.push(bytes, packet.pts, packet.keyFrame);
  }

  Future<bool> _startNative(VideoStreamInfo stream) async {
    if (_nativeUnavailable || !Platform.isWindows || (!stream.isH264 && !stream.isH265)) {
      return false;
    }
    final generation = _generation;
    _nativeStarting = true;
    try {
      final decoder = await NativeVideoDecoder.create(
        stream.width,
        stream.height,
        _forceSoftware ? DecoderMode.software : decoderMode,
        fps: stream.frameRate,
        codecId: stream.codecId,
      );
      if (_disposed || _paused || generation != _generation) {
        await decoder.dispose();
        return true;
      }
      _native = decoder;
      _nativeWaitingKey = true;
      _stage = 'native-h264';
      SessionLog.write(
        '[native] ${stream.codecName} → Media Foundation → texture '
        '${stream.width}x${stream.height}，无 TS/HTTP/JPEG',
      );
      final replay = _lastGop.replay();
      for (final packet in replay) {
        _feedNative(packet);
      }
      if (replay.isEmpty && _receivedPictures > 0) _requestKeyframe();
      videoRevision.value++;
      _nativeTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _pollNative(),
      );
      return true;
    } on MissingPluginException {
      _nativeUnavailable = true;
      if (decoderMode == DecoderMode.hardware) {
        _nativeBackend = 'failed';
        lastError.value = '硬件解码不可用，请选择自动或软件解码';
        return true;
      }
      return false;
    } catch (error) {
      if (!_disposed && !_paused && generation == _generation) {
        SessionLog.write('[native] 初始化失败（${decoderMode.name}）: $error');
        _nativeUnavailable = true;
        if (decoderMode == DecoderMode.hardware) {
          _nativeBackend = 'failed';
          lastError.value = '硬件解码初始化失败: $error；可切换软件解码';
          return true;
        }
      }
      return false;
    } finally {
      if (generation == _generation) _nativeStarting = false;
    }
  }

  Future<void> _pollNative() async {
    final decoder = _native;
    if (decoder == null ||
        _nativePolling ||
        _paused ||
        _disposed ||
        !_visible) {
      return;
    }
    _nativePolling = true;
    final generation = _generation;
    try {
      final stats = await decoder.stats();
      if (_disposed || _paused || !identical(decoder, _native)) return;
      if (stats['needKeyframe'] == true) _requestKeyframe();
      _oldestQueueMs = [
        (stats['dartOldestMs'] as num?)?.toDouble() ?? 0,
        (stats['nativeOldestMs'] as num?)?.toDouble() ?? 0,
      ].reduce((a, b) => a > b ? a : b);
      _pipelineTiming = [
        for (final key in [
          'dartDwell',
          'dartDropDwell',
          'submitCall',
          'nativeDwell',
          'nativeDropDwell',
          'pushTime',
          'texturePull',
          'textureInterval',
          'textureNotifications',
          'textureCoalesced',
          'textureRetries',
          'textureHandoffWaits',
          'textureHandoffPrecise',
          'textureHandoff',
          'gpuAllocations',
          'gpuReuses',
          'dartOldestMs',
          'nativeOldestMs',
          'dartClearDrops',
          'dartGateDrops',
          'dartClears',
          'nativeClearDrops',
          'nativeFallbackDrops',
          'nativeGateDrops',
          'nativeClears',
          'gpuSurface',
        ])
          if (stats.containsKey(key)) '$key=${stats[key]}',
      ].join(' ');
      _nativeSkipped = (stats['skipped'] as num?)?.toInt() ?? 0;
      final error = stats['error'] as String? ?? '';
      final backend = stats['backend'] as String? ?? 'software';
      if (backend != _nativeBackend) {
        SessionLog.write('[native] 实际解码方式: $backend，选择: ${decoderMode.name}');
      }
      _nativeBackend = backend;
      if ((stats['fallback'] as String? ?? '').isNotEmpty) {
        _fallbackReason = switch (stats['fallback']) {
          'gpu-presentation-unavailable' => '共享纹理不可用，保留硬件解码并使用兼容呈现',
          'gpu-presentation-slow' => '共享纹理响应过慢，保留硬件解码并使用兼容呈现',
          _ => '硬件解码不可用，已回退软件解码',
        };
      }
      if (error.isNotEmpty) throw StateError(error);
      final decoded = (stats['decoded'] as num?)?.toInt() ?? 0;
      if (decoded == 0 && _frames > 45 && _sinceStart.inSeconds >= 8) {
        throw StateError('原生解码器收到数据但 8 秒内没有输出画面');
      }
      _nativeQueued = (stats['queued'] as num?)?.toInt() ?? 0;
      _nativePresented = (stats['presented'] as num?)?.toInt() ?? 0;
      _dropped = (stats['dropped'] as num?)?.toInt() ?? 0;
      _nativeDecodeMs = (stats['decodeMs'] as num?)?.toDouble() ?? 0;
      _nativeLocalMs = (stats['localMs'] as num?)?.toDouble() ?? 0;
      if (decoded > _rendered) {
        _nativeWidth = (stats['width'] as num).toInt();
        _nativeHeight = (stats['height'] as num).toInt();
        final first = _rendered == 0;
        _rendered = decoded;
        _outBytes = decoded * _nativeWidth * _nativeHeight * 4;
        _stage = 'native-rendering';
        _watchdogMessage = null;
        lastError.value = null;
        videoRevision.value++;
        if (first) {
          SessionLog.write('[native] 首帧 ${_nativeWidth}x$_nativeHeight');
        }
      }
    } catch (error) {
      if (!_disposed && !_paused && identical(decoder, _native)) {
        SessionLog.write('[native] 解码失败（${decoderMode.name}）: $error');
        _nativeTimer?.cancel();
        _nativeTimer = null;
        _native = null;
        _nativeUnavailable = true;
        await decoder.dispose();
        if (!_disposed && !_paused && generation == _generation) {
          _rendered = 0;
          videoRevision.value++;
          if (decoderMode == DecoderMode.hardware) {
            _nativeBackend = 'failed';
            lastError.value = '硬件解码失败: $error；请切换自动或软件解码';
            return;
          }
          if (decoderMode == DecoderMode.auto &&
              !_forceSoftware &&
              _nativeBackend != 'software') {
            _forceSoftware = true;
            _nativeUnavailable = false;
            _nativeBackend = 'starting';
            _fallbackReason = '硬件解码失败，已回退软件解码';
            _startedAt = DateTime.now();
            final stream = info.value;
            if (stream != null) unawaited(_startDecoder(stream));
            return;
          }
          _fallbackReason = '原生解码失败，已使用软件兼容解码';
          final stream = info.value;
          if (stream != null) unawaited(_startDecoder(stream));
        }
      }
    } finally {
      _nativePolling = false;
    }
  }

  Future<void> _startDecoder(VideoStreamInfo stream) async {
    if (_ffmpeg != null ||
        _native != null ||
        _nativeStarting ||
        _disposed ||
        _paused) {
      return;
    }
    final generation = _generation;
    if (await _startNative(stream)) return;
    if (_disposed || _paused || generation != _generation) return;
    if (decoderMode == DecoderMode.hardware) {
      _nativeBackend = 'failed';
      lastError.value = '当前视频或系统不支持硬件解码，请切换自动或软件解码';
      return;
    }

    final ffmpeg = _ffmpegPath ??= await _locateFfmpeg();
    if (_disposed || _paused || generation != _generation) return;
    if (ffmpeg == null) {
      lastError.value = '找不到 ffmpeg，无法解码视频（安装：winget install ffmpeg）';
      _stage = 'ffmpeg-missing';
      return;
    }
    if (_disposed) return;

    final maxSide = stream.width > stream.height ? stream.width : stream.height;
    final scale = maxSide <= _maxDimension ? 1.0 : _maxDimension / maxSide;
    final width = ((stream.width * scale) / 2).round() * 2;
    final height = ((stream.height * scale) / 2).round() * 2;

    try {
      var server = _server;
      if (server == null) {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        if (_disposed || _paused || generation != _generation) {
          await server.close();
          return;
        }
        _server = server;
        server.listen(_onClient);
      }

      final process = await Process.start(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'info',
        // No `nobuffer`: with FFmpeg 7+ it stalls the h264 decoder on a
        // slow (static-screen) stream until ~20 frames have queued up.
        '-fflags',
        '+discardcorrupt',
        '-flags',
        'low_delay',
        '-probesize',
        '32',
        '-analyzeduration',
        '0',
        '-fpsprobesize',
        '0',
        '-threads',
        '1',
        '-f',
        'mpegts',
        '-i',
        'http://127.0.0.1:${server.port}/live.ts',
        '-an',
        '-vf',
        'scale=$width:$height:flags=fast_bilinear',
        '-fps_mode',
        'passthrough',
        '-f',
        'image2pipe',
        '-flush_packets',
        '1',
        '-vcodec',
        'mjpeg',
        // Frame threading makes mjpeg return every JPEG one frame late
        // (it waits for the next input). Slice threads stay parallel
        // without that extra frame of latency.
        '-thread_type',
        'slice',
        '-threads',
        '4',
        '-huffman',
        'default',
        '-pix_fmt',
        'yuvj420p',
        '-q:v',
        '4',
        '-',
      ], environment: _noProxyEnvironment());
      if (_disposed || _paused || generation != _generation) {
        process.kill();
        return;
      }
      _ffmpeg = process;
      _stage = 'decoding ${width}x$height';
      SessionLog.write(
        '[ffmpeg] 启动 pid=${process.pid} 输出 ${width}x$height '
        '（输入 ${stream.width}x${stream.height}）',
      );

      _stdout = process.stdout.listen((data) {
        if (identical(process, _ffmpeg)) _onStdout(data);
      }, onError: (Object _) {});
      _stderr = process.stderr.listen((data) {
        if (_disposed || !identical(process, _ffmpeg)) return;
        final text = String.fromCharCodes(data).trim();
        if (text.isEmpty) return;
        SessionLog.write('[ffmpeg] $text');
        _lastWarning = text;
        final lower = text.toLowerCase();
        if (lower.contains('non monotonically increasing') ||
            lower.contains('not enough frames to estimate rate')) {
          return;
        }
        if (_rendered > 0) return;
        if (lower.contains('error') ||
            lower.contains('invalid') ||
            lower.contains('failed') ||
            lower.contains('no such') ||
            lower.contains('refused') ||
            lower.contains('does not contain') ||
            lower.contains('unable')) {
          lastError.value = text;
        }
      });
      unawaited(process.exitCode.then((code) => _onFfmpegExit(process, code)));
    } catch (error) {
      if (_disposed || _paused || generation != _generation) return;
      lastError.value = '启动 ffmpeg 失败: $error';
      _stage = 'ffmpeg-failed';
    }
  }

  void _onFfmpegExit(Process process, int code) {
    if (_disposed || _paused || !identical(process, _ffmpeg)) return;
    final generation = _generation;
    _stage = 'ffmpeg-exited:$code';
    SessionLog.write(
      '[ffmpeg] 退出，退出码 $code（第 ${_restarts + 1} 次退出，'
      '已收 $_frames 帧 / $_outBytes 字节输出）',
    );
    _client?.destroy();
    _client = null;
    _stdout?.cancel();
    _stderr?.cancel();
    _ffmpeg = null;
    if (_restarts >= 3) {
      lastError.value = '解码器反复退出（ffmpeg 退出码 $code），视频已停止';
      SessionLog.write('[ffmpeg] 重启次数用尽，停止解码');
      return;
    }
    _restarts++;
    SessionLog.write('[ffmpeg] 300ms 后第 $_restarts 次重启');
    Timer(const Duration(milliseconds: 300), () {
      if (_disposed || _paused || generation != _generation) return;
      final stream = info.value;
      if (stream == null) {
        SessionLog.write('[ffmpeg] 重启跳过：还没有画面参数');
        return;
      }
      _startDecoder(stream);
    });
  }

  static Map<String, String> _noProxyEnvironment() {
    const keys = <String>[
      'http_proxy',
      'HTTP_PROXY',
      'https_proxy',
      'HTTPS_PROXY',
      'all_proxy',
      'ALL_PROXY',
    ];
    return {
      for (final key in keys) key: '',
      'no_proxy': '127.0.0.1,localhost',
      'NO_PROXY': '127.0.0.1,localhost',
    };
  }

  void _onClient(Socket socket) {
    if (_disposed || _paused) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final buffer = <int>[];
    late StreamSubscription<Uint8List> subscription;
    subscription = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        if (buffer.length > 4 &&
            buffer[buffer.length - 4] == 13 &&
            buffer[buffer.length - 3] == 10 &&
            buffer[buffer.length - 2] == 13 &&
            buffer[buffer.length - 1] == 10) {
          subscription.cancel();
          _startStreaming(socket);
        }
      },
      onError: (_) => socket.destroy(),
      onDone: () => socket.destroy(),
      cancelOnError: true,
    );
  }

  void _startStreaming(Socket socket) {
    _client?.destroy();
    socket.done.catchError((_) {});
    try {
      socket.add(
        'HTTP/1.1 200 OK\r\n'
                'Content-Type: video/mp2t\r\n'
                'Cache-Control: no-store\r\n'
                'Connection: close\r\n'
                'Accept-Ranges: none\r\n'
                '\r\n'
            .codeUnits,
      );
      // Reset the TS muxer so continuity counters start cleanly at 0 for this
      // HTTP client connection and replay the latest GOP with SPS/PPS attached
      // directly to the leading IDR frame.
      _muxer.reset();
      _lastPts = -1;
      var replayed = 0;
      final replay = _lastGop.replay();
      for (var i = 0; i < replay.length; i++) {
        final pkt = replay[i];
        final ts = _muxer.accessUnit(
          pkt.data,
          _monotonicPts(pkt.pts),
          configPrefix: i == 0 ? _spsPps : null,
        );
        if (ts.isNotEmpty) {
          socket.add(ts);
          replayed++;
        }
      }
      _needsConfigPrefix = replayed == 0;
      _pending.clear();
      _queuedBytes = 0;
      _waitingForKeyFrame = replayed == 0;
      _client = socket;
      if (replayed == 0) _requestKeyframe();
      _stage = 'served';
      SessionLog.write(
        '[stream] 已发响应头 + config(${_spsPps?.length ?? 0}B) + $replayed 个起始包',
      );
    } catch (error) {
      lastError.value = '建立视频流失败: $error';
      _stage = 'serve-failed';
      _client = null;
    }
  }

  void _onStdout(List<int> data) {
    if (_disposed || data.isEmpty) return;
    _outBytes += data.length;
    if (!_sawJpegBytes) {
      _sawJpegBytes = true;
      SessionLog.write(
        '[jpeg] ffmpeg 开始输出图像，首块 ${data.length} 字节，'
        '魔术字 ${data.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
      );
    }
    _jpegBuffer.addAll(data);

    Uint8List? newestJpeg;
    while (true) {
      final start = _indexOfJpegStart(_jpegBuffer, 0);
      if (start < 0) {
        final keep = _jpegBuffer.isNotEmpty && _jpegBuffer.last == 0xFF ? 1 : 0;
        if (_jpegBuffer.length > keep) {
          _jpegBuffer.removeRange(0, _jpegBuffer.length - keep);
        }
        _scanPos = 0;
        break;
      }
      if (start > 0) {
        _jpegBuffer.removeRange(0, start);
        _scanPos = (_scanPos - start).clamp(2, _jpegBuffer.length);
      } else if (_scanPos < 2) {
        _scanPos = 2;
      }
      final searchFrom = (_scanPos - 1).clamp(2, _jpegBuffer.length);
      final end = _indexOfJpegEnd(_jpegBuffer, searchFrom);
      if (end < 0) {
        _scanPos = _jpegBuffer.length;
        if (_jpegBuffer.length > _maxJpegBytes) {
          _jpegBuffer.clear();
          _scanPos = 0;
        }
        break;
      }
      newestJpeg = Uint8List.fromList(_jpegBuffer.sublist(0, end));
      _jpegBuffer.removeRange(0, end);
      _scanPos = 0;
    }

    if (newestJpeg != null) {
      _decode(newestJpeg);
    }
  }

  Future<void> _decode(Uint8List jpeg) async {
    if (_disposed || _paused) return;
    if (_decoding) {
      _latestJpeg = jpeg;
      return;
    }
    final generation = _generation;
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final decoded = await codec.getNextFrame();
      codec.dispose();
      if (_disposed || _paused || generation != _generation) {
        decoded.image.dispose();
        return;
      }
      _live.add(decoded.image);
      while (_live.length > _liveLimit) {
        _live.removeAt(0).dispose();
      }
      frame.value = decoded.image;
      _rendered++;
      videoRevision.value++;
      _stage = 'rendering';
      if (_rendered == 1) {
        unawaited(_describeFirstFrame(decoded.image));
      }
      if (_watchdogMessage != null || lastError.value != null) {
        _watchdogMessage = null;
        lastError.value = null;
      }
    } catch (error) {
      if (!_disposed && !_paused && generation == _generation) {
        lastError.value = '解码画面失败: $error';
      }
    } finally {
      _decoding = false;
      final latest = _latestJpeg;
      _latestJpeg = null;
      if (latest != null && !_disposed && !_paused) {
        unawaited(_decode(latest));
      }
    }
  }

  Future<void> _describeFirstFrame(ui.Image image) async {
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return;
      final data = bytes.buffer.asUint8List();
      const steps = 24;
      var sum = 0;
      var bright = 0;
      var samples = 0;
      final stepY = (image.height ~/ steps).clamp(1, image.height);
      final stepX = (image.width ~/ steps).clamp(1, image.width);
      for (var y = 0; y < image.height; y += stepY) {
        for (var x = 0; x < image.width; x += stepX) {
          final i = (y * image.width + x) * 4;
          if (i + 2 >= data.length) continue;
          final v = (data[i] + data[i + 1] + data[i + 2]) ~/ 3;
          sum += v;
          if (v > 16) bright++;
          samples++;
        }
      }
      final mean = samples == 0 ? 0 : sum ~/ samples;
      final brightPct = samples == 0 ? 0 : (bright * 100) ~/ samples;
      SessionLog.write(
        '[首帧] ${image.width}x${image.height} 平均亮度=$mean '
        '非黑采样=$brightPct% '
        '($bright/$samples)',
      );
    } catch (error) {
      SessionLog.write('[首帧] 无法采样: $error');
    }
  }

  void _check() {
    if (_disposed || _paused || !_visible) return;
    if (_started && _rendered > 0 && !_detached) {
      _silentTicks = _checkedFrames == _frames ? _silentTicks + 1 : 0;
      _checkedFrames = _frames;
      if (_silentTicks >= 3 && _silentTicks <= 7 && _silentTicks.isOdd) {
        _requestKeyframe();
        SessionLog.write('[采集] $_silentTicks 秒没有新数据，请求完整画面：$debugState');
      }
      if (_silentTicks >= 5 && !_captureStalled) {
        _captureStalled = true;
        lastError.value = '手机画面数据已暂停，正在等待采集恢复；若手机已锁屏，请先解锁';
        SessionLog.write('[采集] 数据暂停：$debugState');
      }
    }
    if (_watchdogMessage != null) return;
    final elapsed = _sinceStart;
    if (elapsed.inSeconds < 8) return;
    String? message;
    if (!_started) {
      message = '手机已连上，但 8 秒内没收到画面参数。';
    } else if (_frames == 0) {
      final stream = info.value;
      message = '手机上报了 ${stream?.width}×${stream?.height}，但 8 秒内没有收到任何视频数据。';
    } else if (_rendered == 0) {
      message = '收到 $_frames 帧视频数据（${_bytes ~/ 1024} KB），但尚未解出画面。';
      if (_frames > 45 && _outBytes == 0 && _restarts == 0) {
        SessionLog.write('[ffmpeg] 收到 $_frames 帧但零输出，重启解码器');
        _restarts = 1;
        _ffmpeg?.kill();
      }
    }
    if (message != null) {
      _watchdogMessage = message;
      lastError.value = message;
    }
  }

  Duration get _sinceStart {
    _startedAt ??= DateTime.now();
    return DateTime.now().difference(_startedAt!);
  }

  static int _indexOfJpegStart(List<int> buffer, int from) {
    for (var i = from; i + 1 < buffer.length; i++) {
      if (buffer[i] == 0xFF && buffer[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  static int _indexOfJpegEnd(List<int> buffer, int from) {
    for (var i = from; i + 1 < buffer.length; i++) {
      if (buffer[i] == 0xFF && buffer[i + 1] == 0xD9) return i + 2;
    }
    return -1;
  }

  Future<String?> _locateFfmpeg() async {
    if (_cachedFfmpegPath != null) return _cachedFfmpegPath;
    final bundled =
        '${File(Platform.resolvedExecutable).parent.path}\\ffmpeg.exe';
    if (File(bundled).existsSync()) {
      _cachedFfmpegPath = bundled;
      return bundled;
    }
    final candidates = <String>[
      if (Platform.environment['LOCALAPPDATA'] != null)
        '${Platform.environment['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links\\ffmpeg.exe',
      'ffmpeg',
    ];
    for (final candidate in candidates) {
      try {
        final probe = await Process.run(candidate, ['-version']);
        if (probe.exitCode == 0) {
          _cachedFfmpegPath = candidate;
          return candidate;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------- widget

  Widget buildVideo() {
    return ValueListenableBuilder<int>(
      valueListenable: videoRevision,
      builder: (context, revision, child) {
        final native = _native;
        if (native != null) {
          return Texture(
            textureId: native.textureId,
            filterQuality: FilterQuality.medium,
          );
        }
        return _buildImageVideo();
      },
    );
  }

  Widget _buildImageVideo() {
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: frame,
      builder: (context, image, child) {
        if (image == null) {
          return const SizedBox.expand(
            child: ColoredBox(color: Color(0xFF000000)),
          );
        }
        return SizedBox.expand(
          child: RawImage(
            image: image,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        );
      },
    );
  }

  String get debugState =>
      'stage=$_stage rendered=$_rendered frames=$_frames in=$_bytes '
      'out=$_outBytes pending=${_pending.length} restarts=$_restarts '
      'drop=$_dropped '
      'requested=${decoderMode.name} backend=${_nativeBackend == "failed"
          ? "failed"
          : _native == null
          ? "ffmpeg"
          : _nativeBackend} '
      'fallback=$_fallbackReason '
      'nativeQueue=$_nativeQueued presented=$_nativePresented skipped=$_nativeSkipped '
      'decodeMs=${_nativeDecodeMs.toStringAsFixed(2)} localMs=${_nativeLocalMs.toStringAsFixed(2)} '
      'keyRequests=$_keyRequests $_pipelineTiming '
      'flutterBuild=${_buildTiming.snapshot(_timingClock.elapsedMicroseconds)} '
      'flutterRaster=${_rasterTiming.snapshot(_timingClock.elapsedMicroseconds)} '
      'warn=${_lastWarning.isEmpty ? '-' : _lastWarning} '
      'error=${lastError.value ?? '-'}';

  Future<void> dispose() async {
    if (trackFlutterFrames) {
      SchedulerBinding.instance.removeTimingsCallback(_frameTimings);
    }
    _keyRequestCooldown?.cancel();
    _navigationTimer?.cancel();
    if (_disposed) return;
    _disposed = true;
    _nativeTimer?.cancel();
    await _native?.dispose();
    _native = null;
    _watchdog?.cancel();
    await _events?.cancel();
    await _stdout?.cancel();
    await _stderr?.cancel();
    try {
      _client?.destroy();
    } catch (_) {}
    await _server?.close();
    try {
      _ffmpeg?.kill();
    } catch (_) {}
    frame.value = null;
    for (final image in _live) {
      image.dispose();
    }
    _live.clear();
    info.dispose();
    lastError.dispose();
    frame.dispose();
    videoRevision.dispose();
  }
}
