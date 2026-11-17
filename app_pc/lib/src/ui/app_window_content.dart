import 'dart:async';

import 'package:dex_link/dex_link.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../decoder_settings.dart';
import '../dex_session.dart';
import '../input.dart';
import '../video_surface.dart';
import '../session_log.dart';

/// A live Android app, contained by the same rectangle as its PC window.
class AppWindowContent extends StatefulWidget {
  const AppWindowContent({
    super.key,
    required this.host,
    required this.task,
    required this.decoderMode,
    required this.onActivate,
    required this.onProblem,
    required this.onResize,
  });
  final String host;
  final Map<String, dynamic> task;
  final DecoderMode decoderMode;
  final void Function(RemoteInput, PhoneVideoSurface) onActivate;
  final ValueChanged<String> onProblem;
  final ValueChanged<Size> onResize;

  @override
  State<AppWindowContent> createState() => _AppWindowContentState();
}

class _AppWindowContentState extends State<AppWindowContent> {
  late final PhoneVideoSurface surface;
  DexSession? session;
  RemoteInput? input;
  StreamSubscription<String>? errors;
  StreamSubscription<DeviceMessage>? messages;
  Size? remoteSize;
  Size? requestedSize;
  Timer? resizeTimer;
  Timer? metricsTimer;
  Timer? feedbackTimer;
  int feedbackReceived = 0;
  int metricTicks = 0, lastReceived = 0, lastDecoded = 0, lastPresented = 0;
  String? failure;

  @override
  void initState() {
    super.initState();
    surface = PhoneVideoSurface(decoderMode: widget.decoderMode);
    surface.videoRevision.addListener(_frameChanged);
    surface.onNeedKeyframe = () => session?.send(ControlMessages.resetVideo());
    surface.setVisible(widget.task['minimized'] != true);
    feedbackTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final received = surface.receivedPictures;
      session?.updateVideoPressure(
        active:
            widget.task['minimized'] != true &&
            received > feedbackReceived &&
            !surface.isPaused &&
            surface.lastError.value == null,
        oldestMs: surface.oldestQueueMs,
      );
      feedbackReceived = received;
    });
    metricsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final received = surface.receivedPictures;
      final decoded = surface.renderedFrames;
      final presented = surface.presentedFrames;
      if (widget.task['minimized'] != true) {
        if (++metricTicks % 5 == 0) {
          SessionLog.write(
            '[应用窗口 ${widget.task['id']}] 收包=${received - lastReceived} 解码=${decoded - lastDecoded} 输出=${presented - lastPresented} fps ${surface.debugState}',
          );
        }
      }
      lastReceived = received;
      lastDecoded = decoded;
      lastPresented = presented;
    });
    unawaited(connect());
  }

  Future<void> connect() async {
    try {
      final endpoint = CaptureEndpoint.parse(widget.task);
      if (endpoint == null) throw StateError('应用画面通道缺失');
      final connected = await DexSession.connect(
        host: widget.host,
        port: endpoint.port,
        directEndpoint: endpoint,
        audio: false,
        capture: const CaptureOptions(bitrate: 6000000),
        onHalfOpen: (value) {
          session = value;
          input = RemoteInput(value, mouse: true);
          unawaited(surface.restart(value.videoEvents));
        },
      );
      if (!mounted) {
        await connected.dispose();
        return;
      }
      messages = connected.deviceMessages.listen((message) {
        if (message is DesktopMessage &&
            mounted &&
            message.data['contentWidth'] is num &&
            message.data['contentHeight'] is num) {
          surface.resizeVideo(
            (message.data['contentWidth'] as num).toInt(),
            (message.data['contentHeight'] as num).toInt(),
          );
          setState(
            () => remoteSize = Size(
              (message.data['contentWidth'] as num).toDouble(),
              (message.data['contentHeight'] as num).toDouble(),
            ),
          );
        }
      });
      errors = connected.errors.listen((message) {
        if (mounted) setState(() => failure = message);
      });
      if (widget.task['focused'] == true && input != null) {
        widget.onActivate(input!, surface);
      }
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      setState(() => failure = '$error');
      widget.onProblem('应用窗口连接失败：$error');
    }
  }

  @override
  void didUpdateWidget(AppWindowContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    surface.setVisible(widget.task['minimized'] != true);
    if (widget.task['focused'] == true &&
        oldWidget.task['focused'] != true &&
        input != null) {
      widget.onActivate(input!, surface);
    }
  }

  void _frameChanged() {
    final dimensions = surface.pictureSize;
    if (dimensions != null && dimensions != _lastSize && mounted) {
      _lastSize = dimensions;
      setState(() {});
    }
  }

  Size? _lastSize;

  @override
  void dispose() {
    resizeTimer?.cancel();
    metricsTimer?.cancel();
    feedbackTimer?.cancel();
    unawaited(messages?.cancel());
    unawaited(errors?.cancel());
    unawaited(session?.dispose());
    surface.videoRevision.removeListener(_frameChanged);
    unawaited(surface.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final phone =
          remoteSize ??
          Size(
            (widget.task['contentWidth'] as num).toDouble(),
            (widget.task['contentHeight'] as num).toDouble(),
          );
      final size = constraints.biggest;
      if (size.width > 0 && size.height > 0 && requestedSize != size) {
        requestedSize = size;
        resizeTimer?.cancel();
        resizeTimer = Timer(const Duration(milliseconds: 240), () {
          if (mounted) widget.onResize(size);
        });
      }
      final aspectDiff = (phone.aspectRatio - size.aspectRatio).abs() / size.aspectRatio;
      final fitted = (aspectDiff < 0.06)
          ? size
          : applyBoxFit(BoxFit.contain, phone, size).destination;
      final rect = Alignment.center.inscribe(fitted, Offset.zero & size);
      input?.updateGeometry(phone: phone, view: rect.size);
      return ColoredBox(
        color: const Color(0xFF16181C),
        child: Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: MouseRegion(
                onEnter: (event) => input?.hover(
                  event.localPosition,
                  action: MotionAction.hoverEnter,
                ),
                onExit: (event) => input?.hover(
                  event.localPosition,
                  action: MotionAction.hoverExit,
                ),
                onHover: (event) => input?.hover(event.localPosition),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    final remote = input;
                    if (remote == null) return;
                    widget.onActivate(remote, surface);
                    if (event.buttons & kBackMouseButton != 0) {
                      session?.back();
                      return;
                    }
                    remote.pointerDown(
                      event.localPosition,
                      buttons: event.buttons & 7,
                    );
                  },
                  onPointerMove: (event) =>
                      input?.pointerMove(event.localPosition),
                  onPointerUp: (event) => input?.pointerUp(event.localPosition),
                  onPointerCancel: (event) =>
                      input?.pointerCancel(event.localPosition),
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      input?.scroll(event.localPosition, event.scrollDelta);
                    }
                  },
                  child: surface.buildVideo(),
                ),
              ),
            ),
            if (failure != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    failure!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
