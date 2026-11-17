import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of a window fit request.
class FitResult {
  const FitResult({required this.size, required this.applied});

  /// Client size the native side settled on, in logical pixels.
  final Size size;

  /// False when an automatic fit was skipped because the user had just moved
  /// or resized the window by hand.
  final bool applied;
}

/// Window geometry helpers, backed by the native runner (`dexlink/window`).
///
/// A phone stream is a fixed aspect ratio, so a 1280x800 window always wastes
/// space on black bars (or, worse, crops). Resizing the window to the phone's
/// shape once the stream resolution is known makes the picture fill the frame
/// and keeps pointer mapping exact.
class DesktopWindow {
  const DesktopWindow._();

  static const MethodChannel _channel = MethodChannel('dexlink/window');

  /// What the native side reports after a projection-mode switch.
  ///
  /// "The frame is still there" has two very different causes -- a message that
  /// never arrived, or a window style that did not change -- and the styles are
  /// the only way to tell them apart from Dart.
  static String descriptor = '未切换';

  /// What the last `fitWindow` call returned.
  ///
  /// The call has two ways to do nothing -- the native side refused the size,
  /// or it skipped an automatic fit because the user had just moved the window
  /// -- and both leave the same 1280x800 rectangle behind. Recorded so the
  /// debug panel can tell them apart instead of guessing.
  static String lastFit = '未调用';

  /// Logical-pixel band along each window edge that Windows reserves for
  /// resizing (mirrors `kResizeGrip` in `flutter_window.cpp`).
  ///
  /// Kept for the hover zone that stays clear of the resize arrows; the resize
  /// itself is answered by the native window and does not depend on Flutter
  /// declining the hit test.
  static const double resizeBand = 8;

  static Future<void> setProjectionMode(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      final reply = await _channel.invokeMapMethod<String, dynamic>(
        'setProjectionMode',
        enabled,
      );
      if (reply == null) {
        descriptor = '无回包';
        return;
      }
      descriptor =
          'projection=${reply['projection']} '
          'caption=${reply['caption']} '
          'thickframe=${reply['thickframe']} '
          '${reply['width']}x${reply['height']} '
          'nccalc=${reply['nccalc']} '
          'hittest=${reply['hittest']}/${reply['hitedge']}';
    } catch (error) {
      descriptor = '失败: $error';
    }
  }

  static Future<void> startDragging() => _command('startDragging');

  static Future<void> minimize() => _command('minimize');
  static Future<void> toggleMaximize() => _command('toggleMaximize');

  static Future<void> _command(String method, [Object? arguments]) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (error) {
      debugPrint('$method failed: $error');
    }
  }

  /// Shapes the window like the phone.
  ///
  /// [auto] marks the fit that runs by itself when a stream starts. That one
  /// also re-centres the window and gives up if the user has just placed it by
  /// hand; an explicit request from the user never does.
  static Future<FitResult?> fit({
    required int width,
    required int height,
    bool auto = false,
  }) async {
    if (width <= 0 || height <= 0) return null;
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.windows) {
      return null;
    }
    try {
      final reply = await _channel.invokeMapMethod<String, dynamic>(
        'fitWindow',
        <String, dynamic>{'width': width, 'height': height, 'auto': auto},
      );
      if (reply == null) {
        lastFit = '无回包（请求 ${width}x$height auto=$auto）';
        return null;
      }
      final w = (reply['width'] as num?)?.toDouble();
      final h = (reply['height'] as num?)?.toDouble();
      if (w == null || h == null) {
        lastFit = '回包缺尺寸（请求 ${width}x$height）';
        return null;
      }
      final applied = reply['applied'] as bool? ?? true;
      lastFit =
          '请求 ${width}x$height auto=$auto -> ${w.toInt()}x${h.toInt()} '
          'applied=$applied';
      return FitResult(size: Size(w, h), applied: applied);
    } catch (error) {
      lastFit = '失败: $error';
      debugPrint('fitWindow failed: $error');
      return null;
    }
  }

  /// Sets the client area to an exact logical size, keeping the position.
  ///
  /// This is the way back from [fit]: the window goes to whatever size it had
  /// before the option reshaped it, so switching the option off is not a
  /// second guess at what the user wants.
  static Future<bool> resize({
    required double width,
    required double height,
  }) async {
    if (width < 200 || height < 200) return false;
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.windows) {
      return false;
    }
    try {
      await _channel.invokeMethod<void>('resize', <String, dynamic>{
        'width': width,
        'height': height,
      });
      return true;
    } catch (error) {
      debugPrint('resize failed: $error');
      return false;
    }
  }
}
