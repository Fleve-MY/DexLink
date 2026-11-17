import 'package:flutter/material.dart';

import '../desktop_items.dart';

/// The PC owns the desktop shell; Android streams only application content.
class DesktopBackdrop extends StatelessWidget {
  const DesktopBackdrop({super.key, this.wallpaper = 'macos_wave', this.store});

  final String wallpaper;
  final DesktopItems? store;

  @override
  Widget build(BuildContext context) {
    if (store != null) {
      return ListenableBuilder(
        listenable: store!,
        builder: (context, _) => RepaintBoundary(
          child: CustomPaint(
            painter: _Wallpaper(store!.wallpaper),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }
    return RepaintBoundary(
      child: CustomPaint(
        painter: _Wallpaper(wallpaper),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Wallpaper extends CustomPainter {
  const _Wallpaper(this.name);
  final String name;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    switch (name) {
      case 'sonoma':
        _paintSonoma(canvas, size, rect);
      case 'monterey':
        _paintMonterey(canvas, size, rect);
      case 'midnight':
        _paintMidnight(canvas, size, rect);
      case 'sequoia':
        _paintSequoia(canvas, size, rect);
      case 'macos_wave':
      default:
        _paintMacosWave(canvas, size, rect);
    }
  }

  void _paintMacosWave(Canvas canvas, Size size, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEAEAF9), Color(0xFFB9C8E7)],
        ).createShader(rect),
    );
    final ribbon = Path()
      ..moveTo(-size.width * .1, size.height * .84)
      ..cubicTo(
        size.width * .22,
        size.height * .12,
        size.width * .55,
        size.height * 1.22,
        size.width * 1.1,
        size.height * .10,
      )
      ..lineTo(size.width * 1.1, size.height)
      ..close();
    canvas.drawPath(
      ribbon,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF798DE1), Color(0xFFB9AAE5)],
        ).createShader(rect),
    );
    final foreground = Path()
      ..moveTo(-size.width * .05, size.height * 1.05)
      ..cubicTo(
        size.width * .24,
        size.height * .34,
        size.width * .54,
        size.height * 1.14,
        size.width * 1.05,
        size.height * .37,
      )
      ..lineTo(size.width * 1.05, size.height * 1.05)
      ..close();
    canvas.drawPath(
      foreground,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF4363BA), Color(0xFF8B90D8)],
        ).createShader(rect),
    );
  }

  void _paintSonoma(Canvas canvas, Size size, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFDECDA), Color(0xFFE9937E)],
        ).createShader(rect),
    );
    final wave1 = Path()
      ..moveTo(-size.width * .1, size.height * .75)
      ..cubicTo(
        size.width * .25,
        size.height * .18,
        size.width * .65,
        size.height * 1.15,
        size.width * 1.15,
        size.height * .25,
      )
      ..lineTo(size.width * 1.15, size.height)
      ..close();
    canvas.drawPath(
      wave1,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFFE56A54), Color(0xFF8B4D86)],
        ).createShader(rect),
    );
    final wave2 = Path()
      ..moveTo(-size.width * .05, size.height * 1.05)
      ..cubicTo(
        size.width * .3,
        size.height * .4,
        size.width * .5,
        size.height * 1.1,
        size.width * 1.05,
        size.height * .45,
      )
      ..lineTo(size.width * 1.05, size.height * 1.05)
      ..close();
    canvas.drawPath(
      wave2,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF673271), Color(0xFFC7525A)],
        ).createShader(rect),
    );
  }

  void _paintMonterey(Canvas canvas, Size size, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F0B1A), Color(0xFF28133E)],
        ).createShader(rect),
    );
    final wave = Path()
      ..moveTo(-size.width * .1, size.height * .85)
      ..cubicTo(
        size.width * .2,
        size.height * .2,
        size.width * .6,
        size.height * 1.2,
        size.width * 1.1,
        size.height * .15,
      )
      ..lineTo(size.width * 1.1, size.height)
      ..close();
    canvas.drawPath(
      wave,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF4C216D), Color(0xFF8B3A82)],
        ).createShader(rect),
    );
    final wave2 = Path()
      ..moveTo(-size.width * .05, size.height * 1.05)
      ..cubicTo(
        size.width * .28,
        size.height * .42,
        size.width * .55,
        size.height * 1.05,
        size.width * 1.05,
        size.height * .42,
      )
      ..lineTo(size.width * 1.05, size.height * 1.05)
      ..close();
    canvas.drawPath(
      wave2,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF221535), Color(0xFF602856)],
        ).createShader(rect),
    );
  }

  void _paintMidnight(Canvas canvas, Size size, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0.2, -0.3),
          radius: 1.2,
          colors: [Color(0xFF1E2638), Color(0xFF0D0F14)],
        ).createShader(rect),
    );
    final accent = Path()
      ..moveTo(-size.width * .1, size.height * .9)
      ..cubicTo(
        size.width * .3,
        size.height * .3,
        size.width * .7,
        size.height * 1.1,
        size.width * 1.1,
        size.height * .35,
      )
      ..lineTo(size.width * 1.1, size.height)
      ..close();
    canvas.drawPath(
      accent,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF141926), Color(0xFF21293B)],
        ).createShader(rect),
    );
  }

  void _paintSequoia(Canvas canvas, Size size, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFC7E2E8), Color(0xFF75A6A8)],
        ).createShader(rect),
    );
    final wave = Path()
      ..moveTo(-size.width * .1, size.height * .8)
      ..cubicTo(
        size.width * .3,
        size.height * .2,
        size.width * .6,
        size.height * 1.1,
        size.width * 1.1,
        size.height * .25,
      )
      ..lineTo(size.width * 1.1, size.height)
      ..close();
    canvas.drawPath(
      wave,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFF38686B), Color(0xFF23444B)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_Wallpaper oldDelegate) => oldDelegate.name != name;
}
