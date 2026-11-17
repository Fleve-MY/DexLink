import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dex_link/dex_link.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chrome_geometry.dart';
import '../clipboard_bridge.dart';
import '../dex_session.dart';
import '../file_client.dart';
import '../input.dart';
import '../remote_text_input.dart';
import '../session_log.dart';
import '../video_surface.dart';
import '../decoder_settings.dart';
import '../desktop_items.dart';
import '../window_fit.dart';
import 'file_browser.dart';
import 'desktop_workspace.dart';
import 'desktop_window_chrome.dart';
import 'app_window_content.dart';
import 'desktop_backdrop.dart';
import 'desktop_shortcuts.dart';
import 'desktop_widgets.dart';
import 'desktop_settings_dialog.dart';
import 'desktop_menu_bar.dart';
import 'desktop_task_overview.dart';
import 'desktop_style.dart';

class DesktopPage extends StatefulWidget {
  const DesktopPage({
    super.key,
    required this.host,
    required this.port,
    this.decoderMode = DecoderMode.auto,
    this.captureOptions,
    this.screenOff = true,
    this.audio = true,
  });

  final String host;
  final int port;
  final DecoderMode decoderMode;
  final CaptureOptions? captureOptions;
  final bool screenOff;
  final bool audio;

  @override
  State<DesktopPage> createState() => _DesktopPageState();
}

enum ConnPhase { connecting, live, frameLost, ended, failed }

class _DesktopPageState extends State<DesktopPage> with WidgetsBindingObserver {
  final FocusNode _focus = FocusNode();
  final GlobalKey _inputAnchor = GlobalKey();
  late final RemoteTextInput _textInput;
  final List<String> _problems = <String>[];
  final ValueNotifier<String> _statusText = ValueNotifier<String>('连接中…');

  DexSession? _session;
  PhoneVideoSurface? _surface;
  RemoteInput? _input;
  RemoteInput? _appInput;
  PhoneVideoSurface? _appSurface;
  DexSession? get _keyboardSession =>
      _info?.appWindows == true ? _appInput?.session : _session;
  VideoStreamInfo? _info;
  List<Map<String, dynamic>> _desktopTasks = [];
  final _overviewTasks = ValueNotifier<List<Map<String, dynamic>>>([]);
  List<Map<String, dynamic>> _desktopApps = [];
  late final DesktopItems _desktopItems;
  ConnPhase _phase = ConnPhase.connecting;
  bool _showDebug = false;
  bool _reconnecting = false;
  bool _frameListenerAttached = false;
  late DecoderMode _decoderMode;
  String? _endReason;

  Timer? _statusTimer;
  Timer? _feedbackTimer;
  int _feedbackReceived = 0;
  Timer? _watchdogTimer;
  int _lastRendered = 0;
  int _fps = 0;
  int _diagnosticTicks = 0;
  final Stopwatch _rateClock = Stopwatch()..start();
  int _rateTime = 0;
  int _lastReceived = 0;
  int _lastDecoded = 0;

  Size _viewSize = Size.zero;
  Rect _videoRect = Rect.zero;
  String? _fittedFor;

  String? _toast;
  VoidCallback? _toastAction;
  Timer? _toastTimer;
  bool _pasting = false;
  bool _phoneDark = false;
  bool _audioMuted = false;
  bool _autoPanelRequested = false;
  Timer? _panelTimer;
  int _clipboardSequence = 0;

  static const double _topBarHeight = 36;
  static const double _bottomBarHeight = 38;

  bool get _desktopMode =>
      (_info?.clientResize ?? false) || (_info?.desktopControl ?? false);

  Size get _phoneSize => _info == null
      ? const Size(1080, 1920)
      : Size(_info!.width.toDouble(), _info!.height.toDouble());

  Size? get _contentSize {
    return _surface?.pictureSize;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _textInput = RemoteTextInput(
      (text) => _keyboardSession?.send(ControlMessages.injectText(text)),
      viewId: () => View.of(context).viewId,
      onDelete: (count) {
        for (var i = 0; i < count; i++) {
          _keyboardSession?.tapKey(AndroidKeycode.delete);
        }
      },
    );
    _focus.addListener(_onInputFocus);
    _decoderMode = widget.decoderMode;
    _desktopItems = DesktopItems(
      onError: (message) => SessionLog.write('[桌面] $message'),
    );
    unawaited(DesktopWindow.setProjectionMode(true));
    _connect();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickStatus(),
    );
    _feedbackTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final surface = _surface;
      if (!mounted || surface == null || _info?.appWindows == true) return;
      final received = surface.receivedPictures;
      _session?.updateVideoPressure(
        active:
            received > _feedbackReceived &&
            !surface.isPaused &&
            surface.lastError.value == null,
        oldestMs: surface.oldestQueueMs,
      );
      _feedbackReceived = received;
    });
    _watchdogTimer = Timer(
      const Duration(seconds: 10),
      () => _settleSilentFailure(_session),
    );
  }

  void _settleSilentFailure(DexSession? session) {
    if (!mounted) return;
    if (_phase != ConnPhase.connecting) return;
    if (_info != null) return;
    if (session != null && !identical(session, _session)) return;
    final rendered = _surface?.renderedFrames ?? 0;
    if (rendered > 0) return;
    SessionLog.write('10 秒内没有收到任何画面参数，按连接失败处理');
    setState(() {
      _phase = ConnPhase.failed;
      _endReason = '未收到手机画面，请在手机端确认已开始投屏';
    });
  }

  Future<void> _fitToPhone() async {
    final info = _info;
    if (info == null) {
      _showToast('等待画面参数…');
      return;
    }
    _fittedFor = '${info.width}x${info.height}';
    await DesktopWindow.fit(
      width: info.width,
      height: info.height,
      auto: false,
    );
  }

  void _onVideoFrame() {
    if (!mounted ||
        (_phase != ConnPhase.connecting && _phase != ConnPhase.failed) ||
        (_surface?.isPaused ?? true) ||
        !(_surface?.hasPicture ?? false)) {
      return;
    }
    setState(() {
      _phase = ConnPhase.live;
      _endReason = null;
      _problems.clear();
    });
    if (widget.screenOff &&
        !_autoPanelRequested &&
        (_info?.panelPower ?? false)) {
      _autoPanelRequested = true;
      _setPhonePanel(false);
    }
  }

  void _setPhonePanel(bool on) {
    if (!(_info?.panelPower ?? false) || _phase != ConnPhase.live) return;
    if (_panelTimer != null) return;
    _session?.send(ControlMessages.setDisplayPower(on));
    setState(() {
      _panelTimer = Timer(const Duration(seconds: 4), () {
        if (!mounted) return;
        setState(() => _panelTimer = null);
        _showToast('手机未确认屏幕操作，请检查手机屏幕状态');
      });
    });
  }

  void _tickStatus() {
    final surface = _appSurface ?? _surface;
    if (surface == null || !mounted) return;
    final rendered = surface.renderedFrames;
    final presented = surface.presentedFrames;
    final now = _rateClock.elapsedMilliseconds;
    final interval = (now - _rateTime).clamp(1, 60000);
    int rate(int current, int previous) =>
        ((current - previous).clamp(0, 1000) * 1000 / interval).round();
    _fps = rate(presented, _lastRendered);
    final received = surface.receivedPictures;
    final inputFps = rate(received, _lastReceived);
    final decodeFps = rate(rendered, _lastDecoded);
    _rateTime = now;
    _lastReceived = received;
    _lastDecoded = rendered;
    _lastRendered = presented;
    if (++_diagnosticTicks % 5 == 0 && _phase == ConnPhase.live) {
      SessionLog.write(
        '[性能] 收包=$inputFps fps 解码=$decodeFps fps 输出=$_fps fps ${surface.debugState}',
      );
    }
    final fps = _fps;
    if (surface.decoderLabel == '解码失败' && surface.lastError.value != null) {
      setState(() {
        _phase = ConnPhase.failed;
        _endReason = surface.lastError.value;
      });
    }
    if (rendered > 0 &&
        !surface.isPaused &&
        (_phase == ConnPhase.connecting || _phase == ConnPhase.failed)) {
      setState(() {
        _phase = ConnPhase.live;
        _endReason = null;
        _problems.clear();
      });
    } else if (_phase == ConnPhase.connecting &&
        rendered == 0 &&
        surface.lastError.value != null) {
      setState(() {
        _phase = ConnPhase.failed;
        _endReason = surface.lastError.value;
      });
    }
    if (_phase == ConnPhase.connecting && surface.status.startsWith('连接已断开')) {
      setState(() {
        _phase = ConnPhase.failed;
        _endReason = '手机端已断开会话';
      });
    }
    switch (_phase) {
      case ConnPhase.live:
        final backend = surface.decoderLabel == '硬件解码' ? '硬解' : '软解';
        _statusText.value = _info?.appWindows == true && _appSurface == null
            ? '桌面就绪'
            : surface.lastError.value != null
            ? '画面未更新 · $backend'
            : fps > 0
            ? '$fps fps · $backend'
            : '已连接 · $backend';
      case ConnPhase.frameLost:
        _statusText.value = '画面中断';
      case ConnPhase.ended:
        _statusText.value = _reconnecting ? '重连中…' : '已结束';
      case ConnPhase.failed:
        _statusText.value = '连接失败';
      case ConnPhase.connecting:
        _statusText.value = '连接中…';
    }
    if (_showDebug) setState(() {});
  }

  // ------------------------------------------------------------- connection

  Future<void> _connect() async {
    final surface = _surface ??= PhoneVideoSurface(
      decoderMode: _decoderMode,
      trackFlutterFrames: true,
    );
    surface.onNeedKeyframe = () => _session?.send(ControlMessages.resetVideo());
    surface.decoderMode = _decoderMode;
    if (!_frameListenerAttached) {
      surface.videoRevision.addListener(_onVideoFrame);
      _frameListenerAttached = true;
    }
    _input ??= RemoteInput(DexSession.placeholder());
    _appInput = null;
    _appSurface = null;
    _desktopTasks = [];
    _overviewTasks.value = [];
    _fittedFor = null;
    _panelTimer?.cancel();
    _panelTimer = null;
    _phoneDark = false;
    _autoPanelRequested = false;
    if (mounted) {
      setState(() {
        _phase = ConnPhase.connecting;
        _endReason = null;
        _info = null;
      });
    }
    SessionLog.write('连接 ${widget.host}:${widget.port}');

    try {
      final session = await DexSession.connect(
        host: widget.host,
        port: widget.port,
        capture: widget.captureOptions,
        audio: widget.audio,
        onHalfOpen: (session) {
          final existing = _session;
          if (existing != null && !identical(existing, session)) {
            unawaited(existing.dispose());
          }
          _session = session;
          _input?.attach(session);
          _watch(session);
          SessionLog.write('两条通道都已建立，等待画面参数');
          if (mounted) setState(() => _phase = ConnPhase.connecting);
          unawaited(surface.restart(session.videoEvents));
        },
      );
      if (!mounted) {
        await session.dispose();
        return;
      }
      debugActiveSurface = surface;
    } catch (error) {
      if (!mounted) return;
      surface.pause();
      setState(() {
        _phase = ConnPhase.failed;
        _endReason = _explain(error);
      });
    }
  }

  void _watch(DexSession session) {
    _audioMuted = false;
    session.audioStatus.listen((message) {
      if (mounted && identical(session, _session)) _showToast(message);
    });
    session.deviceMessages.listen((message) {
      if (!mounted || !identical(session, _session)) return;
      if (message is PanelPowerResult) {
        _panelTimer?.cancel();
        setState(() {
          _panelTimer = null;
          if (message.success) _phoneDark = !message.on;
        });
        SessionLog.write('[手机屏幕] on=${message.on} success=${message.success}');
        _showToast(
          message.success
              ? (message.on ? '已请求点亮手机屏幕' : '已请求关闭手机面板，投屏继续')
              : '手机拒绝了屏幕操作，已尝试恢复亮屏',
        );
      }
    });
    var packets = 0;
    var payloadBytes = 0;
    var firstKeyLogged = false;
    session.videoEvents.listen(
      (event) {
        if (!mounted || !identical(session, _session)) return;
        if (event is VideoStreamStarted) {
          setState(() => _info = event.info);
          SessionLog.write(
            '画面参数 ${event.info.width}x${event.info.height} '
            '（${event.info.deviceName}，${event.info.frameRateLabel}）',
          );
          _showToast(
            '实际画面 ${event.info.width}×${event.info.height} · ${event.info.frameRateLabel}',
          );
          _input?.phoneSize = Size(
            event.info.width.toDouble(),
            event.info.height.toDouble(),
          );
          unawaited(_fitWindow(event.info));
        }
        if (event is VideoFrameReceived) {
          packets++;
          payloadBytes += event.packet.data.length;
          if (!firstKeyLogged) {
            firstKeyLogged = true;
            SessionLog.write(
              '[收包] 首包 ${event.packet.data.length} 字节 '
              'config=${event.packet.config} key=${event.packet.keyFrame}',
            );
          } else if (packets % 60 == 0) {
            SessionLog.write('[收包] $packets 包，共 $payloadBytes 字节');
          }
        }
      },
      onDone: () {
        if (!mounted || !identical(session, _session)) return;
        if (_info != null) return;
        SessionLog.write('画面参数从未到达，判定本次连接失败');
        if (mounted) {
          setState(() {
            _phase = ConnPhase.failed;
            _endReason = '手机未发送画面数据';
          });
        }
      },
    );
    session.errors.listen((message) {
      if (!mounted || !identical(session, _session)) return;
      _onSessionError(session, message);
    });
  }

  void _onSessionError(DexSession session, String message) {
    if (!identical(session, _session)) return;
    final endedByPhone = message.contains('会话已结束');
    final lost = session.videoLost;
    if (lost) {
      _surface?.pause();
      if (mounted) setState(() => _phase = ConnPhase.frameLost);
      return;
    }
    if (message.startsWith('控制通道已断开')) {
      SessionLog.write(message);
      _showToast('未开启手机无障碍服务（当前仅显示画面）', seconds: 4);
      return;
    }
    if (endedByPhone) {
      _surface?.pause();
      if (mounted) {
        setState(() {
          _phase = ConnPhase.ended;
          _endReason = message;
        });
      }
      return;
    }
    _addProblem(message);
  }

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    final old = _session;
    _session = null;
    await old?.dispose();
    await _connect();
    if (mounted) setState(() => _reconnecting = false);
  }

  Future<void> _chooseDecoder() async {
    final selected = await showDialog<DecoderMode>(
      context: context,
      barrierColor: _desktopMode ? DesktopStyle.barrier : null,
      builder: (context) => Theme(
        data: _desktopMode ? DesktopStyle.theme(context) : Theme.of(context),
        child: SimpleDialog(
          title: const Text('视频解码'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                '当前：${_surface?.decoderLabel ?? "等待解码"}'
                '${(_surface?.fallbackReason ?? "").isEmpty ? "" : "\n${_surface!.fallbackReason}"}'
                '\n自动模式会在硬解失败后回退软解。更改后将重新连接。',
              ),
            ),
            for (final mode in DecoderMode.values)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(mode),
                child: Row(
                  children: [
                    Icon(
                      mode == _decoderMode
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    const SizedBox(width: 12),
                    Text(mode.label),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected == _decoderMode || !mounted) return;
    _decoderMode = selected;
    try {
      await DecoderSettings.write(selected);
    } catch (_) {
      if (mounted) _showToast('设置已生效，但无法保存到磁盘');
    }
    if (!mounted) return;
    _lastRendered = 0;
    await _reconnect();
  }

  String _explain(Object error) {
    if (error is SocketException) {
      final code = error.osError?.errorCode;
      if (code == 10061) {
        return '手机拒绝连接，请在手机端重新点击「开始投屏」';
      }
      if (code == 10060 || code == 10051) {
        return '无法连接 ${widget.host}，请检查 Wi-Fi 或 USB 网络共享';
      }
      return '网络错误：${error.message}';
    }
    return error.toString();
  }

  Future<void> _fitWindow(VideoStreamInfo info) async {
    final key = '${info.width}x${info.height}';
    if (_fittedFor == key) return;
    _fittedFor = key;
    await DesktopWindow.fit(
      width: info.width,
      height: info.height,
      auto: false,
    );
  }

  @override
  void dispose() {
    _desktopItems.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(DesktopWindow.setProjectionMode(false));
    _statusTimer?.cancel();
    _feedbackTimer?.cancel();
    _watchdogTimer?.cancel();
    _toastTimer?.cancel();
    _panelTimer?.cancel();
    _statusText.dispose();
    _overviewTasks.dispose();
    _surface?.videoRevision.removeListener(_onVideoFrame);
    _surface?.dispose();
    _session?.dispose();
    _focus.removeListener(_onInputFocus);
    _textInput.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _addProblem(String message) {
    SessionLog.write('[问题] $message');
    if (!mounted) return;
    setState(() {
      _problems.remove(message);
      _problems.insert(0, message);
      if (_problems.length > 3) _problems.removeLast();
    });
  }

  // ------------------------------------------------------------- clipboard/files

  void _openFiles() {
    showDialog<void>(
      context: context,
      barrierColor: _desktopMode ? DesktopStyle.barrier : null,
      builder: (context) => Theme(
        data: _desktopMode ? DesktopStyle.theme(context) : Theme.of(context),
        child: FileBrowserDialog(host: widget.host, port: widget.port),
      ),
    );
  }

  Future<void> _pasteFromPc() async {
    if (_pasting) return;
    _pasting = true;
    try {
      final item = WindowsClipboard.read();
      switch (item) {
        case ClipboardFiles(:final paths):
          await _pasteFiles(paths);
          return;
        case ClipboardImage(:final bytes, :final extension):
          await _pasteImage(bytes, extension);
          return;
        case ClipboardPlainText(:final text):
          _pasteText(text);
          return;
        case null:
          break;
      }
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isEmpty) {
        _showToast('电脑剪贴板为空');
        return;
      }
      _pasteText(text);
    } catch (error) {
      _showToast('粘贴失败：$error');
    } finally {
      _pasting = false;
    }
  }

  Future<void> _pasteImage(Uint8List bytes, String extension) async {
    final files = await _clipboardFiles();
    final target = await _attachmentTarget(files);
    if (extension == 'bmp') {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          final png = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (png == null) throw const FormatException('无法转换剪贴板图片');
          bytes = png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
          extension = 'png';
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    final remote = 'Download/DexLink/${_uniqueName('clipboard.$extension')}';
    _showToast('发送剪贴板图片…', seconds: 30);
    await files.pushBytes(bytes: bytes, remotePath: remote);
    await _pasteUploaded(files, [remote], target: target);
  }

  void _pasteText(String text) {
    final session = _keyboardSession;
    if (session == null) {
      _showToast('尚未连接手机');
      return;
    }
    _textInput.reset();
    session.send(
      ControlMessages.setClipboard(
        sequence: ++_clipboardSequence,
        text: text,
        paste: true,
      ),
    );
    final preview = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final short = preview.length > 24
        ? '${preview.substring(0, 24)}…'
        : preview;
    _showToast('已粘贴：$short');
  }

  Future<void> _pasteFiles(List<String> paths) async {
    if (paths.isEmpty || paths.length > 32) {
      throw ArgumentError('一次请选择 1～32 个文件');
    }
    for (final path in paths) {
      if (!await File(path).exists()) {
        throw FileSystemException('仅支持现有文件，暂不支持文件夹', path);
      }
    }
    final files = await _clipboardFiles();
    final target = await _attachmentTarget(files);
    const inbox = 'Download/DexLink';

    final remotes = <String>[];
    for (final path in paths) {
      final source = File(path);
      final name = source.uri.pathSegments.lastWhere(
        (s) => s.isNotEmpty,
        orElse: () => 'clipboard.bin',
      );
      final remote = '$inbox/${_uniqueName(name)}';
      _showToast('发送 $name…', seconds: 30);
      await files.push(
        source: source,
        remotePath: remote,
        onProgress: (done, total) {
          if (total <= 0) return;
          final percent = (done * 100 / total).round();
          _showToast('发送 $name · $percent%', seconds: 30);
        },
      );
      remotes.add(remote);
    }
    await _pasteUploaded(files, remotes, target: target);
  }

  Future<PhoneFiles> _clipboardFiles() async {
    final files = PhoneFiles(host: widget.host, port: widget.port);
    await files.mkdir('Download/DexLink');
    return files;
  }

  Future<void> _pasteUploaded(
    PhoneFiles files,
    List<String> paths, {
    required Map<String, dynamic> target,
  }) async {
    final result = await files.pasteAttachments(paths, target: target);
    final canShare = result.accepted == 0 && result.clipboardReady;
    _showToast(
      result.message,
      seconds: canShare ? 15 : 6,
      action: canShare ? () => unawaited(_shareUploaded(files, paths)) : null,
    );
  }

  Future<void> _shareUploaded(PhoneFiles files, List<String> paths) async {
    _showToast('准备分享…');
    try {
      _showToast(await files.shareAttachments(paths), seconds: 10);
    } catch (error) {
      _showToast('分享失败：$error', seconds: 6);
    }
  }

  Future<Map<String, dynamic>> _attachmentTarget(PhoneFiles files) async {
    final target = await files.pasteTarget();
    if (_info?.appWindows == true) {
      final focused = _desktopTasks.where(
        (task) => task['focused'] == true && task['minimized'] != true,
      );
      if (focused.isEmpty) throw StateError('请先点选应用输入框');
      final task = focused.first;
      final package = '${task['component'] ?? ''}'.split('/').first;
      if ('${target['token'] ?? ''}'.isNotEmpty &&
          (target['package'] != package ||
              target['display'] != task['displayId'])) {
        throw StateError('请先在目标窗口点选输入框');
      }
    }
    return target;
  }

  String _uniqueName(String name) {
    final stamp =
        '${DateTime.now().microsecondsSinceEpoch}-${++_clipboardSequence}';
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '$name-$stamp';
    return '${name.substring(0, dot)}-$stamp${name.substring(dot)}';
  }

  // ------------------------------------------------------------------ chrome

  void _showToast(String message, {int seconds = 3, VoidCallback? action}) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _toast = message;
      _toastAction = action;
    });
    _toastTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      setState(() {
        _toast = null;
        _toastAction = null;
      });
    });
  }

  void _onInputFocus() => _textInput.focus(_focus.hasPrimaryFocus);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _textInput.focus(
      state == AppLifecycleState.resumed && _focus.hasPrimaryFocus,
    );
  }

  void _updateInputAnchor(Offset point) {
    final box = _inputAnchor.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final x = point.dx.clamp(0.0, box.size.width - 1).toDouble();
    final y = point.dy
        .clamp(0.0, (box.size.height - 20).clamp(0.0, double.infinity))
        .toDouble();
    _textInput.setGeometry(
      box.size,
      box.getTransformTo(null),
      Rect.fromLTWH(x, y, 1, 20),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;
    if (_textInput.composing) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      final pressed = HardwareKeyboard.instance;
      if (event.logicalKey == LogicalKeyboardKey.f12) {
        setState(() => _showDebug = !_showDebug);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.f11) {
        unawaited(_fitToPhone());
        return KeyEventResult.handled;
      }
      if (pressed.isControlPressed &&
          event.logicalKey == LogicalKeyboardKey.keyV) {
        _pasteFromPc();
        return KeyEventResult.handled;
      }
    }
    final handled =
        (_info?.appWindows == true ? _appInput : _input)?.handleKey(
          event,
          sendText: false,
        ) ??
        false;
    if (handled) _textInput.reset();
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _desktopMode ? DesktopStyle.theme(context) : Theme.of(context),
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0E14),
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_desktopMode) DesktopBackdrop(store: _desktopItems),
              SizedBox.expand(
                child: Column(
                  children: [
                    _buildTopBar(),
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(child: _buildVideo()),
                          if (_info?.appWindows == true && _session != null)
                            Positioned.fill(
                              bottom: 84,
                              child: DesktopShortcuts(
                                apps: _desktopApps,
                                store: _desktopItems,
                                onWidgets: () =>
                                    showDesktopWidgets(context, _desktopItems),
                                onRefresh: () => _session?.send(
                                  ControlMessages.desktop({'action': 'apps'}),
                                ),
                                onLaunch: (component) => _session?.send(
                                  ControlMessages.desktop({
                                    'action': 'launch',
                                    'component': component,
                                    'layout': _desktopItems.layoutFor(
                                      component,
                                    ),
                                  }),
                                ),
                              ),
                            ),
                          if (_info?.appWindows == true)
                            Positioned.fill(
                              bottom: 84,
                              child: DesktopWidgets(store: _desktopItems),
                            ),
                          if ((_info?.desktopControl ?? false) &&
                              _session != null &&
                              _phase == ConnPhase.live)
                            Positioned.fill(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final viewport = Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  );
                                  final rect = _info?.appWindows == true
                                      ? Offset.zero & viewport
                                      : videoBoxFor(
                                          viewport,
                                          content: _contentSize ?? _phoneSize,
                                        );
                                  return DesktopWindowChrome(
                                    session: _session!,
                                    onLayout: _desktopItems.setAppLayout,
                                    contentBuilder: (task) => AppWindowContent(
                                      key: ValueKey(
                                        '${task['id']}:${task['streamToken']}',
                                      ),
                                      host: widget.host,
                                      task: task,
                                      decoderMode: _decoderMode,
                                      onProblem: _showToast,
                                      onResize: (size) {
                                        final scale = (1.5)
                                            .clamp(0.1, 2880 / size.width)
                                            .clamp(0.1, 2160 / size.height);
                                        final width =
                                            ((size.width * scale).round().clamp(
                                              240,
                                              2880,
                                            )) &
                                            ~1;
                                        final height =
                                            ((size.height * scale)
                                                .round()
                                                .clamp(240, 2160)) &
                                            ~1;
                                        _session?.send(
                                          ControlMessages.desktop({
                                            'action': 'resizeContent',
                                            'taskId': task['id'],
                                            'width': width,
                                            'height': height,
                                          }),
                                        );
                                      },
                                      onActivate: (remote, appSurface) {
                                        _textInput.reset();
                                        if (!identical(
                                          _appSurface,
                                          appSurface,
                                        )) {
                                          _lastRendered =
                                              appSurface.presentedFrames;
                                          _lastReceived =
                                              appSurface.receivedPictures;
                                          _lastDecoded =
                                              appSurface.renderedFrames;
                                          _rateTime =
                                              _rateClock.elapsedMilliseconds;
                                        }
                                        _appSurface = appSurface;
                                        _appInput = remote;
                                        if (task['focused'] != true) {
                                          _session?.send(
                                            ControlMessages.desktop({
                                              'action': 'focus',
                                              'taskId': task['id'],
                                            }),
                                          );
                                        }
                                        _focus.requestFocus();
                                        _textInput.focus(true);
                                      },
                                    ),
                                    tasks: [
                                      for (final task in _desktopTasks)
                                        {
                                          ...task,
                                          for (final app in _desktopApps)
                                            if ('${app['component']}'
                                                        .split('/')
                                                        .first ==
                                                    '${task['component']}'
                                                        .split('/')
                                                        .first &&
                                                app['icon'] is String)
                                              'icon': app['icon'],
                                        },
                                    ],
                                    desktopSize: _phoneSize,
                                    videoRect: rect,
                                  );
                                },
                              ),
                            ),
                          if ((_info?.desktopControl ?? false) &&
                              _session != null &&
                              _phase == ConnPhase.live)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: DesktopWorkspace(
                                key: ObjectKey(_session),
                                session: _session!,
                                items: _desktopItems,
                                onProblem: _showToast,
                                onAddShortcut: (app) {
                                  _desktopItems.addApp(
                                    app['component'] as String,
                                    '${app['label']}',
                                  );
                                  _showToast('已添加「${app['label']}」到桌面');
                                },
                                onInteraction: () => _focus.requestFocus(),
                                onWidgets: () =>
                                    showDesktopWidgets(context, _desktopItems),
                                layoutForApp: _desktopItems.layoutFor,
                                onState: (data) {
                                  if (data['apps'] case final List apps) {
                                    setState(
                                      () => _desktopApps = apps
                                          .whereType<Map<String, dynamic>>()
                                          .toList(),
                                    );
                                  }
                                  if (data['tasks'] case final List current) {
                                    if (!current.any(
                                      (task) =>
                                          task is Map &&
                                          task['focused'] == true &&
                                          task['minimized'] != true,
                                    )) {
                                      _appInput = null;
                                      _appSurface = null;
                                    }
                                  }
                                  if (data['tasks'] case final List tasks
                                      when jsonEncode(tasks) !=
                                          jsonEncode(_desktopTasks)) {
                                    setState(
                                      () => _desktopTasks = tasks
                                          .whereType<Map<String, dynamic>>()
                                          .toList(),
                                    );
                                    _overviewTasks.value = _desktopTasks;
                                  }
                                },
                              ),
                            ),
                          if (_connectOverlayVisible)
                            Positioned.fill(
                              child: _buildConnectOverlay(context),
                            ),
                          if (_problems.isNotEmpty) _buildProblems(context),
                          if (_showDebug)
                            Positioned(
                              left: 10,
                              right: 10,
                              top: 10,
                              child: SingleChildScrollView(
                                child: _buildDebug(),
                              ),
                            ),
                          if (_toast != null) _buildToast(),
                        ],
                      ),
                    ),
                    if (!_desktopMode) _buildBottomBar(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _connectOverlayVisible =>
      _phase != ConnPhase.live || !(_surface?.hasPicture ?? false);

  bool get _canReconnect => switch (_phase) {
    ConnPhase.frameLost || ConnPhase.ended || ConnPhase.failed => true,
    ConnPhase.live => _session == null,
    ConnPhase.connecting => false,
  };

  Widget _buildVideo() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final view = Size(constraints.maxWidth, constraints.maxHeight);
        final content = _contentSize ?? _phoneSize;
        final box = videoBoxFor(view, content: content);
        _viewSize = view;
        _videoRect = box;
        _input?.updateGeometry(phone: _phoneSize, view: box.size);
        return Listener(
          key: _inputAnchor,
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _textInput.reset();
            _updateInputAnchor(event.localPosition);
            _focus.requestFocus();
            if (_focus.hasPrimaryFocus) _textInput.focus(true);
            if (event.buttons & kSecondaryMouseButton != 0) {
              _session?.back();
              return;
            }
            _input?.pointerDown(_toPicture(event.localPosition));
          },
          onPointerMove: (event) =>
              _input?.pointerMove(_toPicture(event.localPosition)),
          onPointerUp: (event) =>
              _input?.pointerUp(_toPicture(event.localPosition)),
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _input?.scroll(
                _toPicture(event.localPosition),
                event.scrollDelta,
              );
            }
          },
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF000000)),
                if (_info?.appWindows == true)
                  Positioned.fill(child: DesktopBackdrop(store: _desktopItems))
                else if (_surface != null)
                  Positioned.fromRect(rect: box, child: _surface!.buildVideo()),
              ],
            ),
          ),
        );
      },
    );
  }

  Offset _toPicture(Offset local) => local - _videoRect.topLeft;

  Widget _buildConnectOverlay(BuildContext context) {
    final surface = _surface;
    final (title, body, canRetry) = switch (_phase) {
      ConnPhase.connecting => (
        '正在连接 ${widget.host}:${widget.port}',
        surface?.status ?? '正在建立视频与控制通道…',
        false,
      ),
      ConnPhase.live => ('正在准备画面', surface?.status ?? '等待第一帧…', false),
      ConnPhase.frameLost => ('画面已中断', '手机停止了画面传输，可点击重试恢复连接。', true),
      ConnPhase.ended => ('投屏已结束', _endReason ?? '手机端已停止本次会话。', true),
      ConnPhase.failed => ('无法建立连接', _endReason ?? '请检查手机端是否已点击「开始投屏」。', true),
    };
    final failed = _phase != ConnPhase.connecting && _phase != ConnPhase.live;

    return ColoredBox(
      color: const Color(0xF20B0E14),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Container(
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            decoration: BoxDecoration(
              color: const Color(0xFF141A26),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: failed
                    ? const Color(0x55F87171)
                    : const Color(0xFF232D42),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!failed)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0x22EF4444),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.portable_wifi_off,
                      color: Color(0xFFF87171),
                      size: 20,
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (canRetry) ...[
                      FilledButton.icon(
                        onPressed: _reconnecting ? null : _reconnect,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(_reconnecting ? '连接中…' : '重试'),
                      ),
                      const SizedBox(width: 10),
                    ],
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Dedicated top window header bar above the phone screen.
  ///
  /// Because it sits in a [Column] above the video canvas rather than floating
  /// over the top of the phone screen, it never blocks the phone's status bar
  /// and never intercepts pull-down notification/control-center gestures.
  Widget _buildTopBar() {
    if (_desktopMode) {
      final focused = _desktopTasks.where(
        (task) => task['focused'] == true && task['minimized'] != true,
      );
      return DesktopMenuBar(
        activeApp: focused.isEmpty
            ? '桌面'
            : '${focused.first['label'] ?? '应用窗口'}',
        connected: _phase == ConnPhase.live,
        audioEnabled: widget.audio,
        audioMuted: _audioMuted,
        onAudio: () {
          setState(() => _audioMuted = !_audioMuted);
          _session?.setAudioMuted(_audioMuted);
        },
        onAction: _desktopMenuAction,
        onDrag: () => unawaited(DesktopWindow.startDragging()),
        onMaximize: () => unawaited(DesktopWindow.toggleMaximize()),
        onMinimize: () => unawaited(DesktopWindow.minimize()),
        onClose: () => Navigator.of(context).maybePop(),
        settings: _buildDesktopSettings(),
      );
    }
    final info = _info;
    return Container(
      height: _topBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _desktopMode ? const Color(0xFFF5F6F8) : const Color(0xFF111621),
        border: Border(
          bottom: BorderSide(
            color: _desktopMode
                ? const Color(0xFFDADDE2)
                : const Color(0x1FFFFFFF),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => unawaited(DesktopWindow.startDragging()),
              onDoubleTap: () => unawaited(
                _desktopMode ? DesktopWindow.toggleMaximize() : _fitToPhone(),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  Icon(
                    _desktopMode
                        ? Icons.desktop_windows_outlined
                        : Icons.smartphone,
                    size: 14,
                    color: _desktopMode
                        ? const Color(0xFF58616D)
                        : const Color(0xFF60A5FA),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _desktopMode
                          ? 'DexLink 桌面'
                          : info?.deviceName ?? widget.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _desktopMode
                            ? const Color(0xFF30343A)
                            : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildStatusPill(),
                ],
              ),
            ),
          ),
          if (_desktopMode) _buildDesktopSettings(),
          _iconBtn(
            icon: const Icon(Icons.fit_screen, size: 15),
            tooltip: '适配窗口比例 (F11)',
            onTap: () => unawaited(_fitToPhone()),
          ),
          _iconBtn(
            icon: const Icon(Icons.content_paste, size: 14),
            tooltip: '粘贴剪贴板 (Ctrl+V)',
            onTap: _pasting ? null : _pasteFromPc,
          ),
          _iconBtn(
            icon: const Icon(Icons.folder_open, size: 15),
            tooltip: '文件传输',
            onTap: _openFiles,
          ),
          _iconBtn(
            icon: const Icon(Icons.bug_report_outlined, size: 15),
            tooltip: '诊断信息 (F12)',
            active: _showDebug,
            onTap: () => setState(() => _showDebug = !_showDebug),
          ),
          _iconBtn(
            icon: const Icon(Icons.memory, size: 15),
            tooltip: '视频解码设置',
            onTap: _reconnecting ? null : _chooseDecoder,
          ),
          _iconBtn(
            icon: const Icon(Icons.remove, size: 15),
            tooltip: '最小化',
            onTap: () => unawaited(DesktopWindow.minimize()),
          ),
          if (_desktopMode)
            _iconBtn(
              icon: const Icon(Icons.crop_square, size: 13),
              tooltip: '最大化 / 还原桌面窗口',
              onTap: () => unawaited(DesktopWindow.toggleMaximize()),
            ),
          _iconBtn(
            icon: const Icon(Icons.close, size: 15),
            tooltip: '断开连接',
            danger: true,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  void _desktopMenuAction(String action) {
    switch (action) {
      case 'home':
        _session?.send(
          ControlMessages.desktop({
            'action': 'home',
            if (_info?.appWindows == true) 'clientViewport': true,
          }),
        );
      case 'widgets':
        showDesktopWidgets(context, _desktopItems);
      case 'settings':
        showDesktopSettings(context, _desktopItems);
      case 'overview':
        _showDesktopOverview();
      case 'files':
        _openFiles();
      case 'paste':
        if (!_pasting) _pasteFromPc();
      case 'decoder':
        if (!_reconnecting) _chooseDecoder();
      case 'diagnostics':
        setState(() => _showDebug = !_showDebug);
      case 'maximize':
        unawaited(DesktopWindow.toggleMaximize());
      case 'exit':
        Navigator.of(context).maybePop();
    }
  }

  Future<void> _showDesktopOverview() async {
    final selected = await showDialog<int>(
      context: context,
      barrierColor: DesktopStyle.barrier,
      builder: (_) => ValueListenableBuilder<List<Map<String, dynamic>>>(
        valueListenable: _overviewTasks,
        builder: (_, tasks, _) => DesktopTaskOverview(
          tasks: tasks,
          apps: _desktopApps,
          onAction: (action, id) => _session?.send(
            ControlMessages.desktop({
              'action': action,
              'taskId': id,
              if (_info?.appWindows == true) 'clientViewport': true,
            }),
          ),
        ),
      ),
    );
    if (!mounted ||
        selected == null ||
        !_desktopTasks.any((task) => task['id'] == selected)) {
      return;
    }
    _session?.send(
      ControlMessages.desktop({
        'action': 'focus',
        'taskId': selected,
        if (_info?.appWindows == true) 'clientViewport': true,
      }),
    );
  }

  // Desktop sessions expose session settings without Android navigation.
  Widget _buildDesktopSettings() => PopupMenuButton<String>(
    tooltip: '桌面会话设置',
    position: PopupMenuPosition.under,
    offset: const Offset(0, 6),
    color: DesktopStyle.surface,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: DesktopStyle.line, width: .7),
    ),
    icon: const Icon(
      Icons.settings_outlined,
      color: Color(0xFF58616D),
      size: 16,
    ),
    onSelected: (value) {
      if (value == 'audio') {
        setState(() => _audioMuted = !_audioMuted);
        _session?.setAudioMuted(_audioMuted);
      } else if (value == 'panel') {
        _setPhonePanel(_phoneDark);
      }
    },
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: 'audio',
        height: 38,
        checked: widget.audio && !_audioMuted,
        enabled: widget.audio,
        child: const Text('电脑播放手机声音'),
      ),
      PopupMenuItem(
        value: 'panel',
        height: 38,
        enabled:
            (_info?.panelPower ?? false) &&
            _phase == ConnPhase.live &&
            _panelTimer == null,
        child: Text(_phoneDark ? '点亮手机屏幕' : '关闭手机面板（不锁屏）'),
      ),
    ],
  );

  /// Navigation and phone controls belong only to screen mirroring.
  Widget _buildBottomBar() {
    return Container(
      height: _bottomBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF111621),
        border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _iconBtn(
            icon: const Icon(Icons.arrow_back_ios_new, size: 14),
            tooltip: '返回 (右键 / Esc)',
            onTap: () => _session?.back(),
          ),
          _iconBtn(
            icon: const Icon(Icons.circle_outlined, size: 15),
            tooltip: '主屏幕',
            onTap: () {
              SessionLog.write('[导航] 点击 Home');
              _session?.goHome();
              _surface?.expectNavigationFrame();
            },
          ),
          _iconBtn(
            icon: const Icon(Icons.crop_square_rounded, size: 15),
            tooltip: '最近任务',
            onTap: () => _session?.showRecents(),
          ),
          _barDivider(),
          _iconBtn(
            icon: const Icon(Icons.notifications_none, size: 16),
            tooltip: '展开通知栏',
            onTap: () =>
                _session?.send(ControlMessages.expandNotificationPanel()),
          ),
          _iconBtn(
            icon: const Icon(Icons.tune, size: 15),
            tooltip: '展开控制中心 / 快捷设置',
            onTap: () => _session?.send(ControlMessages.expandSettingsPanel()),
          ),
          _iconBtn(
            icon: const Icon(Icons.screen_rotation, size: 14),
            tooltip: '旋转屏幕',
            onTap: () => _session?.rotate(),
          ),
          _iconBtn(
            icon: Icon(
              _audioMuted || !widget.audio
                  ? Icons.headset_off
                  : Icons.headphones,
              size: 15,
            ),
            tooltip: !widget.audio
                ? '连接设置中开启手机声音'
                : (_audioMuted ? '恢复电脑播放手机声音' : '静音电脑上的手机声音'),
            active: widget.audio && !_audioMuted,
            onTap: !widget.audio
                ? null
                : () {
                    setState(() => _audioMuted = !_audioMuted);
                    _session?.setAudioMuted(_audioMuted);
                    _showToast(_audioMuted ? '已静音电脑上的手机声音' : '已恢复手机声音播放');
                  },
          ),
          _iconBtn(
            icon: const Icon(Icons.volume_up, size: 15),
            tooltip: '手机音量 +',
            onTap: () => _session?.volumeUp(),
          ),
          _iconBtn(
            icon: const Icon(Icons.volume_down, size: 15),
            tooltip: '手机音量 -',
            onTap: () => _session?.volumeDown(),
          ),
          _iconBtn(
            icon: Icon(
              _phoneDark ? Icons.brightness_5 : Icons.brightness_2,
              size: 15,
            ),
            tooltip: (_info?.panelPower ?? false)
                ? (_phoneDark ? '点亮手机屏幕' : '息屏投屏（不锁屏）')
                : '息屏投屏需要手机 Shizuku 增强采集支持',
            active: _phoneDark,
            onTap:
                (_info?.panelPower ?? false) &&
                    _phase == ConnPhase.live &&
                    _panelTimer == null
                ? () => _setPhonePanel(_phoneDark)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _barDivider() => Container(
    width: 1,
    height: 16,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    color: const Color(0x24FFFFFF),
  );

  Widget _iconBtn({
    required Widget icon,
    required String tooltip,
    VoidCallback? onTap,
    bool active = false,
    bool danger = false,
  }) {
    final fg = onTap == null
        ? (_desktopMode ? Colors.black26 : Colors.white24)
        : danger
        ? const Color(0xFFFCA5A5)
        : active
        ? const Color(0xFF60A5FA)
        : _desktopMode
        ? const Color(0xFF41474F)
        : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: SizedBox(
        width: _desktopMode ? 40 : 28,
        height: _desktopMode ? 32 : 28,
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 400),
          child: Material(
            color: active
                ? const Color(0x333B82F6)
                : _desktopMode
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.05),
            shape: _desktopMode
                ? const RoundedRectangleBorder()
                : const CircleBorder(),
            child: InkWell(
              customBorder: _desktopMode
                  ? const RoundedRectangleBorder()
                  : const CircleBorder(),
              onTap: onTap,
              hoverColor: danger
                  ? const Color(0xFFE81123)
                  : _desktopMode
                  ? const Color(0xFFDADDE2)
                  : Colors.white.withValues(alpha: 0.16),
              child: IconTheme(
                data: IconThemeData(color: fg, size: 15),
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill() {
    return ValueListenableBuilder<String>(
      valueListenable: _statusText,
      builder: (context, text, child) {
        final color = switch (_phase) {
          ConnPhase.live => const Color(0xFF22C55E),
          ConnPhase.connecting => const Color(0xFFF59E0B),
          _ => const Color(0xFFEF4444),
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(
                text,
                style: TextStyle(
                  color: _desktopMode
                      ? const Color(0xFF656D78)
                      : const Color(0xFFE2E8F0),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToast() {
    return Positioned(
      left: 14,
      right: 14,
      bottom: 16,
      child: IgnorePointer(
        ignoring: _toastAction == null,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xEB111621),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0x28FFFFFF)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _toast ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                if (_toastAction != null) ...[
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: _toastAction,
                    child: const Text('分享至应用'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDebug() {
    final surface = _surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xE80D121C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF25344D)),
      ),
      child: Text(
        'phase=${_phase.name} session=${_session == null ? 'none' : 'open'}\n'
        '${surface?.debugState ?? 'no surface'}\n'
        'sourceHz=${_session?.sourceRefreshHz?.toStringAsFixed(1) ?? "unknown"} '
        'requestedHz=${_session?.requestedRefreshHz?.toStringAsFixed(1) ?? "unknown"}\n'
        'view=${_viewSize.width.toInt()}x${_viewSize.height.toInt()} '
        'picture=${_videoRect.width.toInt()}x${_videoRect.height.toInt()}'
        '@${_videoRect.left.toInt()},${_videoRect.top.toInt()}\n'
        'hittest=${DesktopWindow.descriptor} '
        'fit=${DesktopWindow.lastFit}\n'
        'log=${SessionLog.path}'
        '${SessionLog.failure == null ? '' : '\nlog-error=${SessionLog.failure}'}',
        style: const TextStyle(
          color: Color(0xFF94A3B8),
          fontSize: 10.5,
          fontFamily: 'Consolas',
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildProblems(BuildContext context) {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xF0281317),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x66F87171)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _problems.first,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11.5),
              ),
            ),
            if (_canReconnect)
              TextButton(
                onPressed: _reconnecting ? null : _reconnect,
                child: const Text('重连'),
              ),
            IconButton(
              onPressed: () => setState(_problems.clear),
              icon: const Icon(Icons.close, size: 15, color: Colors.white54),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
