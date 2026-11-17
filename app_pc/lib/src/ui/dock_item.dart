import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'desktop_dock.dart';

/// A stationary input target with a spring-driven visual icon above it.
class DockItem extends StatefulWidget {
  const DockItem({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.running = false,
    this.onMenu,
    this.launchFeedback = false,
  });
  final String label;
  final Widget icon;
  final VoidCallback onTap;
  final bool active, running, launchFeedback;
  final ValueChanged<Offset>? onMenu;
  @override
  State<DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<DockItem> with TickerProviderStateMixin {
  late final motion = AnimationController.unbounded(vsync: this);
  late final launch = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  late final entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();
  ValueNotifier<Offset?>? pointer;
  bool pressed = false, focused = false, hovered = false, reduced = false;
  double target = 0;

  @override
  void didUpdateWidget(DockItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) track();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = DockPointer.of(context);
    if (next != pointer) {
      pointer?.removeListener(track);
      pointer = next;
      pointer?.addListener(track);
    }
    final wasReduced = reduced;
    reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      target = 0;
      motion.value = 0;
      launch.value = 0;
      entrance.value = 1;
    } else if (wasReduced || pointer?.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) track();
      });
    }
  }

  void track() {
    if (!mounted || reduced) return;
    final point = pointer?.value;
    final box = context.findRenderObject() as RenderBox?;
    var next = 0.0;
    if (point != null && box != null && box.hasSize) {
      final local = box.globalToLocal(point);
      final distance = (local.dx - box.size.width / 2).abs();
      if (distance < 112 && local.dy > 0 && local.dy < box.size.height) {
        next = (math.cos(distance / 112 * math.pi) + 1) / 2;
      }
    }
    retarget(next);
  }

  void retarget(double next) {
    if ((next - target).abs() < .002) return;
    target = next;
    if (reduced) {
      motion.value = 0;
      return;
    }
    motion.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 520, damping: 44),
        motion.value,
        next,
        motion.velocity,
      ),
    );
  }

  void activateItem() {
    // This cue acknowledges the click, not a completed Android app launch.
    if (widget.launchFeedback && !widget.running && !reduced && hovered) {
      launch.forward(from: 0);
    }
    widget.onTap();
  }

  @override
  void dispose() {
    pointer?.removeListener(track);
    motion.dispose();
    launch.dispose();
    entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.label,
    preferBelow: false,
    waitDuration: const Duration(milliseconds: 300),
    decoration: BoxDecoration(
      color: const Color(0xF22A3448),
      borderRadius: BorderRadius.circular(9),
    ),
    textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            widget.onMenu != null &&
            (event.logicalKey == LogicalKeyboardKey.contextMenu ||
                (event.logicalKey == LogicalKeyboardKey.f10 &&
                    HardwareKeyboard.instance.isShiftPressed))) {
          final box = context.findRenderObject() as RenderBox;
          widget.onMenu!(box.localToGlobal(Offset(box.size.width / 2, 28)));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          hovered = true;
          if (pointer == null) retarget(1);
        },
        onExit: (_) {
          hovered = false;
          if (pointer == null) retarget(0);
          if (pressed) setState(() => pressed = false);
        },
        child: Semantics(
          button: true,
          label: widget.label,
          selected: widget.active,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              onFocusChange: (value) => setState(() => focused = value),
              onTapDown: (_) => setState(() => pressed = true),
              onTapUp: (_) => setState(() => pressed = false),
              onTapCancel: () => setState(() => pressed = false),
              onTap: activateItem,
              onSecondaryTapDown: widget.onMenu == null
                  ? null
                  : (event) => widget.onMenu!(event.globalPosition),
              child: SizedBox(
                width: 64,
                height: 110,
                child: AnimatedBuilder(
                  animation: Listenable.merge([motion, launch, entrance]),
                  child: RepaintBoundary(
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: widget.icon,
                        ),
                      ),
                    ),
                  ),
                  builder: (_, icon) {
                    final amount = reduced ? 0.0 : motion.value.clamp(0.0, 1.0);
                    final bounce = reduced
                        ? 0.0
                        : math.sin(launch.value * math.pi * 2).abs() *
                              (1 - launch.value) *
                              14;
                    final arrival = reduced
                        ? 1.0
                        : Curves.easeOutCubic.transform(entrance.value);
                    return Opacity(
                      opacity: arrival,
                      child: Transform.translate(
                        offset: Offset(0, (1 - arrival) * 8),
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.bottomCenter,
                          children: [
                            Positioned(
                              bottom: 29,
                              child: Transform.translate(
                                offset: Offset(0, -amount * 6 - bounce),
                                child: Transform.scale(
                                  key: ValueKey('dock-icon-${widget.label}'),
                                  scale:
                                      (1 + amount * .4) * (pressed ? .94 : 1),
                                  alignment: Alignment.bottomCenter,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: focused
                                          ? Border.all(
                                              color: const Color(0xFF366CC8),
                                              width: 2,
                                            )
                                          : null,
                                    ),
                                    child: icon,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              bottom: 21,
                              child: AnimatedContainer(
                                key: ValueKey('dock-running-${widget.label}'),
                                duration: reduced
                                    ? Duration.zero
                                    : const Duration(milliseconds: 160),
                                width: widget.running ? 4 : 0,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: widget.active
                                      ? const Color(0xFF454451)
                                      : const Color(0xFF656471),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
