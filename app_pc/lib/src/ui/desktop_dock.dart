import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Stable hit slots keep magnified icons from moving the pointer's target.
class DesktopDock extends StatefulWidget {
  const DesktopDock({
    super.key,
    required this.children,
    this.autoHide = false,
  });
  final List<Widget> children;
  final bool autoHide;
  @override
  State<DesktopDock> createState() => _DesktopDockState();
}

class _DesktopDockState extends State<DesktopDock> {
  final pointer = ValueNotifier<Offset?>(null);
  final scroll = ScrollController();
  bool hovered = false;
  @override
  void dispose() {
    pointer.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contrast = MediaQuery.highContrastOf(context);
    return SizedBox(
      height: 110,
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.translucent,
        onHover: (event) {
          if (!widget.autoHide || hovered || event.localPosition.dy >= 80) {
            if (!hovered) setState(() => hovered = true);
          }
        },
        onExit: (_) {
          if (hovered) setState(() => hovered = false);
          pointer.value = null;
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedSlide(
              offset: Offset(0, widget.autoHide && !hovered ? 1.05 : 0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: RepaintBoundary(
                child: DockPointer(
                  pointer: pointer,
                  child: MouseRegion(
                    onHover: (event) {
                      pointer.value = event.position;
                    },
                    child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent &&
                        scroll.hasClients &&
                        scroll.position.maxScrollExtent > 0) {
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (_) {
                          scroll.jumpTo(
                            (scroll.offset +
                                    event.scrollDelta.dy +
                                    event.scrollDelta.dx)
                                .clamp(0, scroll.position.maxScrollExtent),
                          );
                          pointer.value = null;
                        },
                      );
                    }
                  },
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 16,
                        height: 68,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x200F132A),
                                blurRadius: 30,
                                spreadRadius: -6,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(
                                sigmaX: contrast ? 0 : 22,
                                sigmaY: contrast ? 0 : 22,
                              ),
                              child: DecoratedBox(
                                key: const ValueKey('desktop-dock-glass'),
                                decoration: BoxDecoration(
                                  color: contrast
                                      ? const Color(0xFFF0F3FA)
                                      : const Color(0x78F8F7FC),
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(
                                    color: contrast
                                        ? const Color(0xFF43516A)
                                        : const Color(0xA6FFFFFF),
                                    width: .6,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SingleChildScrollView(
                        controller: scroll,
                        scrollDirection: Axis.horizontal,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: widget.children,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class DockPointer extends InheritedWidget {
  const DockPointer({super.key, required this.pointer, required super.child});
  final ValueNotifier<Offset?> pointer;
  static ValueNotifier<Offset?>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockPointer>()?.pointer;
  @override
  bool updateShouldNotify(DockPointer oldWidget) =>
      pointer != oldWidget.pointer;
}

class DockSeparator extends StatelessWidget {
  const DockSeparator({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 14,
    height: 110,
    child: Padding(
      padding: EdgeInsets.only(top: 51, bottom: 31),
      child: VerticalDivider(width: 14, thickness: 1, color: Color(0x332C3E5C)),
    ),
  );
}

/// Original DexLink tools; phone apps continue to use their own icons.
class DockToolIcon extends StatelessWidget {
  const DockToolIcon({super.key, required this.icon, required this.colors});
  final IconData icon;
  final List<Color> colors;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0x44FFFFFF)),
    ),
    child: CustomPaint(
      painter: _DockToolPainter(icon),
      child: const SizedBox.expand(),
    ),
  );
}

class _DockToolPainter extends CustomPainter {
  const _DockToolPainter(this.icon);
  final IconData icon;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 44, size.height / 44);
    final white = Paint()..color = const Color(0xFFF9FAFF);
    if (icon == Icons.apps_rounded) {
      const colors = [
        Color(0xFFFFE2B9),
        Color(0xFFDCD7FF),
        Color(0xFFE2F4FF),
        Color(0xFFD6F3ED),
        Color(0xFFFFFFFF),
        Color(0xFFEACFFF),
        Color(0xFFFAD6E4),
        Color(0xFFCDDCF9),
        Color(0xFFFFE5C8),
      ];
      for (var row = 0; row < 3; row++) {
        for (var col = 0; col < 3; col++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(9 + col * 9, 9 + row * 9, 7, 7),
              const Radius.circular(2),
            ),
            Paint()..color = colors[row * 3 + col],
          );
        }
      }
    } else if (icon == Icons.view_quilt_outlined) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(9, 10, 27, 22),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0x66FFFFFF),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(7, 14, 21, 20),
          const Radius.circular(3),
        ),
        white,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(10, 18, 15, 12),
          const Radius.circular(1.5),
        ),
        Paint()..color = const Color(0xFFA38AD7),
      );
      canvas.drawLine(
        const Offset(11, 16),
        const Offset(16, 16),
        Paint()
          ..color = const Color(0xFFCABBE5)
          ..strokeWidth = 1,
      );
    } else {
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: 25,
            color: Colors.white,
          ),
        ),
      )..layout();
      painter.paint(
        canvas,
        Offset((44 - painter.width) / 2, (44 - painter.height) / 2),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DockToolPainter oldDelegate) => icon != oldDelegate.icon;
}
