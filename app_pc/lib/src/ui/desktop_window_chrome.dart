import 'dart:async';

import 'package:dex_link/dex_link.dart';
import 'package:flutter/material.dart';

import '../dex_session.dart';
import 'phone_app_icon.dart';
import 'desktop_style.dart';

/// Windows chrome belongs to DexLink; Android continues to own app surfaces.
class DesktopWindowChrome extends StatefulWidget {
  const DesktopWindowChrome({
    super.key,
    required this.session,
    required this.tasks,
    required this.desktopSize,
    required this.videoRect,
    this.contentBuilder,
    this.onLayout,
  });
  final Widget Function(Map<String, dynamic>)? contentBuilder;
  final void Function(String component, String layout)? onLayout;
  final DexSession session;
  final List<Map<String, dynamic>> tasks;
  final Size desktopSize;
  final Rect videoRect;

  @override
  State<DesktopWindowChrome> createState() => _DesktopWindowChromeState();
}

class _DesktopWindowChromeState extends State<DesktopWindowChrome> {
  int? _dragTask;
  Rect? _preview;
  Rect? _original;
  Offset _delta = Offset.zero;
  Timer? _commitTimeout;

  @override
  void didUpdateWidget(DesktopWindowChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_original != null || _dragTask == null) return;
    for (final task in widget.tasks) {
      if (task['id'] == _dragTask && bounds(task) == _preview) {
        _commitTimeout?.cancel();
        _dragTask = null;
        _preview = null;
        break;
      }
    }
  }

  @override
  void dispose() {
    _commitTimeout?.cancel();
    super.dispose();
  }

  static Rect? bounds(Map<String, dynamic> task) {
    final parts = RegExp(r'-?\d+')
        .allMatches('${task['bounds']}')
        .map((m) => double.parse(m[0]!))
        .toList();
    if (parts.length != 4 || parts[2] <= parts[0] || parts[3] <= parts[1]) {
      return null;
    }
    return Rect.fromLTRB(parts[0], parts[1], parts[2], parts[3]);
  }

  void _command(
    String action,
    int id, [
    Map<String, Object> values = const {},
  ]) {
    widget.session.send(
      ControlMessages.desktop({
        'action': action,
        'taskId': id,
        if (widget.contentBuilder != null) 'clientViewport': true,
        ...values,
      }),
    );
  }

  void _start(int id, Rect rect) {
    _commitTimeout?.cancel();
    _command('focus', id);
    setState(() {
      _dragTask = id;
      _original = _preview = rect;
      _delta = Offset.zero;
    });
  }

  Future<void> _windowMenu(
    Map<String, dynamic> task,
    Offset position,
    bool maximized,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const DesktopMenuItem(value: 'minimize', child: Text('最小化')),
        DesktopMenuItem(
          value: maximized ? 'restore' : 'maximize',
          child: Text(maximized ? '恢复窗口' : '最大化'),
        ),
        const DesktopMenuItem(value: 'left', child: Text('靠左排列')),
        const DesktopMenuItem(value: 'right', child: Text('靠右排列')),
        const PopupMenuDivider(),
        const DesktopMenuItem(value: 'close', child: Text('关闭窗口')),
      ],
    );
    if (mounted && action != null) _command(action, task['id'] as int);
  }

  void _update(
    Offset change, {
    required bool resize,
    Alignment edge = Alignment.bottomRight,
  }) {
    final original = _original;
    if (original == null || widget.videoRect.width <= 0) return;
    _delta += Offset(
      change.dx * widget.desktopSize.width / widget.videoRect.width,
      change.dy * widget.desktopSize.height / widget.videoRect.height,
    );
    final size = widget.desktopSize;
    setState(() {
      if (resize) {
        final minW = 320.0.clamp(
          0,
          edge.x < 0 ? original.right : size.width - original.left,
        );
        final minH = 240.0.clamp(
          0,
          edge.y < 0 ? original.bottom : size.height - original.top,
        );
        _preview = Rect.fromLTRB(
          edge.x < 0
              ? (original.left + _delta.dx).clamp(0, original.right - minW)
              : original.left,
          edge.y < 0
              ? (original.top + _delta.dy).clamp(0, original.bottom - minH)
              : original.top,
          edge.x > 0
              ? (original.right + _delta.dx).clamp(
                  original.left + minW,
                  size.width,
                )
              : original.right,
          edge.y > 0
              ? (original.bottom + _delta.dy).clamp(
                  original.top + minH,
                  size.height,
                )
              : original.bottom,
        );
      } else {
        _preview = Rect.fromLTWH(
          (original.left + _delta.dx).clamp(0, size.width - original.width),
          (original.top + _delta.dy).clamp(0, size.height - original.height),
          original.width,
          original.height,
        );
      }
    });
  }

  void _end() {
    final id = _dragTask, rect = _preview;
    if (id != null && rect != null) {
      _command('bounds', id, {
        'x': rect.left.round(),
        'y': rect.top.round(),
        'width': rect.width.round(),
        'height': rect.height.round(),
      });
    }
    setState(() {
      _original = null;
    });
    _commitTimeout = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _dragTask = null;
          _preview = null;
        });
      }
    });
  }

  Rect _screen(Rect rect) {
    final scale = widget.videoRect.width / widget.desktopSize.width;
    final scaleY = widget.videoRect.height / widget.desktopSize.height;
    return Rect.fromLTWH(
      widget.videoRect.left + rect.left * scale,
      widget.videoRect.top + rect.top * scaleY,
      rect.width * scale,
      rect.height * scaleY,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.tasks
        .where(
          (task) =>
              task['windowingMode'] == 5 &&
              (task['minimized'] != true || task['kind'] == 'appWindow'),
        )
        .toList();
    return Stack(
      children: [
        for (var index = tasks.length - 1; index >= 0; index--)
          if (bounds(tasks[index]) case final Rect actual)
            Positioned.fill(
              key: ValueKey(tasks[index]['id']),
              child: Offstage(
                offstage: tasks[index]['minimized'] == true,
                child: ClipPath(
                  clipper: _WindowOcclusion([
                    for (var foreground = 0; foreground < index; foreground++)
                      if (tasks[foreground]['minimized'] != true)
                        if (bounds(tasks[foreground]) case final Rect front)
                          _screen(
                            front,
                          ).expandToInclude(_screen(front).translate(0, -32)),
                  ]),
                  child: Stack(children: _window(tasks[index], actual)),
                ),
              ),
            ),
      ],
    );
  }

  List<Widget> _window(Map<String, dynamic> task, Rect actual) {
    final id = task['id'] as int;
    final mapped = _screen(_dragTask == id ? _preview ?? actual : actual);
    final rect = task['kind'] == 'appWindow'
        ? Rect.fromLTRB(
            mapped.left,
            mapped.top.clamp(widget.videoRect.top + 32, mapped.bottom - 1),
            mapped.right,
            mapped.bottom,
          )
        : mapped;
    const titleHeight = 32.0;
    final maximized =
        actual.width >= widget.desktopSize.width - 2 &&
        actual.height >=
            widget.desktopSize.height - (task['kind'] == 'appWindow' ? 42 : 2);
    final top = (rect.top - titleHeight).clamp(
      widget.videoRect.top,
      widget.videoRect.bottom - titleHeight,
    );
    return [
      if (task['kind'] == 'appWindow' && widget.contentBuilder != null)
        Positioned.fromRect(
          rect: rect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: task['focused'] == true
                    ? const Color(0x33000000)
                    : const Color(0x1F000000),
                width: 0.6,
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(task['focused'] == true ? 0x38000000 : 0x20000000),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: Color(task['focused'] == true ? 0x14000000 : 0x0A000000),
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(7),
                ),
                child: widget.contentBuilder!(task),
              ),
            ),
          ),
        ),
      if (_dragTask == id)
        Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0x1638BDF8),
                border: Border.all(color: const Color(0xFF71B9F5), width: 2),
              ),
            ),
          ),
        ),
      Positioned(
        key: ValueKey('window-title-$id'),
        left: rect.left,
        top: top,
        width: rect.width,
        height: titleHeight,
        child: Material(
          color: task['focused'] == true
              ? const Color(0xF8F1F3F6)
              : const Color(0xF0E4E7EB),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(maximized ? 0 : 10),
            ),
            side: BorderSide(
              color: task['focused'] == true
                  ? const Color(0x28000000)
                  : const Color(0x18000000),
              width: 0.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              if (task['icon'] is String)
                Padding(
                  padding: const EdgeInsets.only(left: 10, right: 6),
                  child: PhoneAppIcon(
                    encoded: task['icon'] as String,
                    size: 16,
                  ),
                )
              else
                const SizedBox(width: 10),
              MouseRegion(
                cursor: SystemMouseCursors.move,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _command('focus', id),
                  onDoubleTap: () =>
                      _command(maximized ? 'restore' : 'maximize', id),
                  onSecondaryTapUp: (event) =>
                      _windowMenu(task, event.globalPosition, maximized),
                  onPanStart: (_) => _start(id, actual),
                  onPanUpdate: (event) => _update(event.delta, resize: false),
                  onPanEnd: (_) => _end(),
                  onPanCancel: () => setState(() {
                    _dragTask = null;
                    _preview = _original = null;
                  }),
                  child: Text(
                    '${task['label']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: task['focused'] == true
                          ? const Color(0xFF1E2128)
                          : const Color(0xFF757B88),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _command('focus', id),
                    onDoubleTap: () =>
                        _command(maximized ? 'restore' : 'maximize', id),
                    onSecondaryTapUp: (event) =>
                        _windowMenu(task, event.globalPosition, maximized),
                    onPanStart: (_) => _start(id, actual),
                    onPanUpdate: (event) => _update(event.delta, resize: false),
                    onPanEnd: (_) => _end(),
                    onPanCancel: () => setState(() {
                      _dragTask = null;
                      _preview = _original = null;
                    }),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              if (task['layout'] is String)
                PopupMenuButton<String>(
                  tooltip: '应用布局',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 180),
                  icon: const Icon(
                    Icons.view_quilt_outlined,
                    size: 16,
                    color: Color(0xFF515968),
                  ),
                  onSelected: (layout) {
                    if (task['component'] case final String component) {
                      widget.onLayout?.call(component, layout);
                    }
                    _command('layout', id, {'layout': layout});
                    if (layout == 'phone') {
                      _snapToPhone(id, actual);
                    } else if (actual.width < 540) {
                      _snapToTablet(id, actual, layout);
                    }
                  },
                  itemBuilder: (context) => [
                    for (final entry in const {
                      'responsive': '随窗口自适应（无黑边）',
                      'tabletWide': '宽屏平板（大视野）',
                      'tablet': '平板布局（默认）',
                      'phone': '手机比例',
                    }.entries)
                      CheckedPopupMenuItem(
                        value: entry.key,
                        checked: task['layout'] == entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                ),
              _windowButton(
                tip: '最小化窗口',
                icon: Icons.remove,
                onTap: () => _command('minimize', id),
              ),
              _windowButton(
                tip: maximized ? '恢复窗口大小' : '最大化窗口',
                icon: maximized ? Icons.filter_none : Icons.crop_square,
                onTap: () => _command(maximized ? 'restore' : 'maximize', id),
              ),
              _windowButton(
                tip: '关闭窗口',
                icon: Icons.close,
                onTap: () => _command('close', id),
                danger: true,
              ),
            ],
          ),
        ),
      ),
      Positioned(
        left: rect.right - 18,
        top: rect.bottom - 18,
        width: 18,
        height: 18,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _start(id, actual),
            onPanUpdate: (event) => _update(event.delta, resize: true),
            onPanEnd: (_) => _end(),
            onPanCancel: () => setState(() {
              _dragTask = null;
              _preview = _original = null;
            }),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      for (final edge in [
        Alignment.topLeft,
        Alignment.topCenter,
        Alignment.topRight,
        Alignment.centerLeft,
        Alignment.centerRight,
        Alignment.bottomLeft,
        Alignment.bottomCenter,
      ])
        Positioned.fromRect(
          rect: Rect.fromCenter(
            center: Offset(
              rect.left + (edge.x + 1) * rect.width / 2,
              edge.y < 0 ? top : rect.top + (edge.y + 1) * rect.height / 2,
            ),
            width: edge.x == 0
                ? (rect.width - 32).clamp(0, double.infinity)
                : 8,
            height: edge.y == 0
                ? (rect.height - 32).clamp(0, double.infinity)
                : 8,
          ),
          child: MouseRegion(
            cursor: edge.x == 0
                ? SystemMouseCursors.resizeUpDown
                : edge.y == 0
                ? SystemMouseCursors.resizeLeftRight
                : edge.x == edge.y
                ? SystemMouseCursors.resizeUpLeftDownRight
                : SystemMouseCursors.resizeUpRightDownLeft,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _start(id, actual),
              onPanUpdate: (event) =>
                  _update(event.delta, resize: true, edge: edge),
              onPanEnd: (_) => _end(),
              onPanCancel: () => setState(() {
                _dragTask = null;
                _preview = _original = null;
              }),
            ),
          ),
        ),
    ];
  }



  void _snapToPhone(int id, Rect actual) {
    final h = (widget.desktopSize.height - 80).clamp(480.0, 780.0);
    final w = (h * 9 / 16).roundToDouble();
    final x = (actual.center.dx - w / 2).clamp(0.0, widget.desktopSize.width - w);
    const y = 42.0;
    _command('bounds', id, {
      'x': x.toInt(),
      'y': y.toInt(),
      'width': w.toInt(),
      'height': h.toInt(),
    });
  }

  void _snapToTablet(int id, Rect actual, String layout) {
    if (actual.width < 540) {
      final w = (layout == 'tabletWide' ? 1040.0 : 860.0).clamp(320.0, widget.desktopSize.width);
      final h = 640.0.clamp(240.0, widget.desktopSize.height - 60);
      final x = ((widget.desktopSize.width - w) / 2).clamp(0.0, widget.desktopSize.width - w);
      const y = 42.0;
      _command('bounds', id, {
        'x': x.toInt(),
        'y': y.toInt(),
        'width': w.toInt(),
        'height': h.toInt(),
      });
    }
  }

  Widget _windowButton({
    required String tip,
    required IconData icon,
    required VoidCallback onTap,
    bool danger = false,
  }) => SizedBox(
    width: 38,
    height: 32,
    child: Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        hoverColor: danger ? const Color(0xFFE81123) : const Color(0x18000000),
        child: Center(
          child: Icon(
            icon,
            size: 13,
            color: danger ? null : const Color(0xFF2E333D),
          ),
        ),
      ),
    ),
  );

}

class _WindowOcclusion extends CustomClipper<Path> {
  const _WindowOcclusion(this.foreground);
  final List<Rect> foreground;

  @override
  Path getClip(Size size) {
    var path = Path()..addRect(Offset.zero & size);
    for (final rect in foreground) {
      path = Path.combine(
        PathOperation.difference,
        path,
        Path()..addRect(rect),
      );
    }
    return path;
  }

  @override
  bool shouldReclip(_WindowOcclusion oldClipper) => true;
}
