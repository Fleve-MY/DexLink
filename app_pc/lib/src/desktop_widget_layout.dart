import 'dart:math' as math;
import 'dart:ui';

/// Preferred geometry and its reference workspace are persisted together.
/// Legacy normalized positions are resolved once, before saving pixel positions.
abstract final class DesktopWidgetLayout {
  static double number(Object? value, double fallback) =>
      value is num && value.isFinite ? value.toDouble() : fallback;

  static Size preferredSize(Map<String, dynamic> item) {
    final large = item['large'] == true;
    final calendar = item['kind'] == 'calendar';
    final clock = item['kind'] == 'clock';
    return Size(
      number(
        item['width'],
        calendar ? (large ? 380 : 320) : (large ? 360 : 260),
      ).clamp(240, 640),
      number(
        item['height'],
        calendar
            ? (large ? 480 : 420)
            : clock
            ? (large ? 200 : 160)
            : (large ? 320 : 220),
      ).clamp(clock ? 140 : 180, 720),
    );
  }

  static Offset preferredPosition(Map<String, dynamic> item, Size area) {
    final size = preferredSize(item);
    return Offset(
      number(
        item['left'],
        number(item['x'], .75).clamp(0, 1) *
            math.max(0, area.width - size.width),
      ),
      number(
        item['top'],
        number(item['y'], .05).clamp(0, 1) *
            math.max(0, area.height - size.height),
      ),
    );
  }

  static Rect fit(Offset origin, Size size, Size area) {
    final width = math.min(size.width, math.max(0.0, area.width));
    final height = math.min(size.height, math.max(0.0, area.height));
    return Rect.fromLTWH(
      origin.dx.clamp(0, math.max(0.0, area.width - width)),
      origin.dy.clamp(0, math.max(0.0, area.height - height)),
      width,
      height,
    );
  }

  static Rect resolve(Map<String, dynamic> item, Size area) => scaleRect(
    fit(
      preferredPosition(item, referenceArea(item, area)),
      preferredSize(item),
      logicalArea(item, area),
    ),
    scale(item, area),
  );

  static Size referenceArea(Map<String, dynamic> item, Size area) => Size(
    number(item['workspaceWidth'], area.width).clamp(1, double.infinity),
    number(item['workspaceHeight'], area.height).clamp(1, double.infinity),
  );

  static double scale(Map<String, dynamic> item, Size area) {
    return scaleFor(area, referenceArea(item, area));
  }

  static double scaleFor(Size area, Size reference) {
    return math
        .min(
          1.0,
          math.min(
            area.width / reference.width,
            area.height / reference.height,
          ),
        )
        .clamp(.001, 1.0);
  }

  static Size workspace(Iterable<Map<String, dynamic>> items, Size area) {
    var width = 0.0, height = 0.0;
    for (final item in items) {
      if (item['workspaceWidth'] is num && item['workspaceHeight'] is num) {
        final reference = referenceArea(item, area);
        width = math.max(width, reference.width);
        height = math.max(height, reference.height);
      }
    }
    if (width > 0 && height > 0) return Size(width, height);
    width = area.width;
    height = area.height;
    // Older layouts did not record their workspace. Preserve the extent of
    // saved positions instead of first clamping distant widgets on top of others.
    for (final item in items) {
      final size = preferredSize(item);
      width = math.max(width, number(item['left'], 0) + size.width);
      height = math.max(height, number(item['top'], 0) + size.height);
    }
    return Size(math.max(1, width), math.max(1, height));
  }

  static Size logicalArea(Map<String, dynamic> item, Size area) =>
      area / scale(item, area);

  static Rect scaleRect(Rect rect, double scale) => Rect.fromLTWH(
    rect.left * scale,
    rect.top * scale,
    rect.width * scale,
    rect.height * scale,
  );
}
