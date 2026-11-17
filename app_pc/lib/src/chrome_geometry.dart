import 'dart:ui' show Offset, Rect, Size;

/// Which overlay panels should be on screen for a given pointer position.
class ChromeTarget {
  const ChromeTarget({required this.top, required this.left});

  final bool top;
  final bool left;

  bool get any => top || left;

  @override
  String toString() => 'ChromeTarget(top: $top, left: $left)';
}

/// Hit zones for the auto-hiding chrome.
///
/// While a panel is visible its zone grows to cover the panel itself, otherwise
/// the panel would vanish the moment the pointer left the 26 px edge strip and
/// the user could never click a button.
ChromeTarget chromeTargetFor(
  Offset position, {
  required bool topVisible,
  required bool leftVisible,
  double edgeReach = 26,
  double topHeight = 44,
  double railWidth = 46,
}) {
  final inTop =
      position.dy <= edgeReach || (topVisible && position.dy <= topHeight + 10);
  final inLeft =
      position.dx <= edgeReach ||
      (leftVisible && position.dx <= railWidth + 14);
  return ChromeTarget(top: inTop, left: inLeft);
}

/// The box a phone picture of [content] fills inside the area [view].
///
/// This is `BoxFit.contain` written out. It exists as a function because the
/// same rectangle has to drive three separate things -- where the picture is
/// painted, where a click lands, and which part of the window is "the window"
/// rather than a letterbox bar -- and a `RawImage`'s internal alignment is not
/// observable to any of them.
///
/// [content] is the size of the image Flutter actually received, i.e. the
/// *decoded* size, not the phone's screen size. They differ: the pipeline caps
/// the decoded height at 1600 logical pixels, so a 864x1920 stream arrives as
/// 720x1600. Using the phone size here instead stretches the mapping by 10%
/// and clicks land slightly off.
Rect videoBoxFor(Size view, {required Size content}) {
  if (view.width <= 0 || view.height <= 0) return Rect.zero;
  if (content.width <= 0 || content.height <= 0) {
    return Offset.zero & view;
  }
  final aspect = content.width / content.height;
  if (!aspect.isFinite || aspect <= 0) return Offset.zero & view;
  var width = view.width;
  var height = width / aspect;
  if (height > view.height) {
    height = view.height;
    width = height * aspect;
  }
  return Rect.fromLTWH(
    (view.width - width) / 2,
    (view.height - height) / 2,
    width,
    height,
  );
}
