import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../desktop_items.dart';
import '../desktop_widget_layout.dart';
import 'desktop_clock.dart';
import 'desktop_todo.dart';
import 'desktop_style.dart';

const _kinds = {'clock': '时钟', 'calendar': '日历', 'note': '便签', 'todo': '待办清单'};

Future<void> showDesktopWidgets(
  BuildContext context,
  DesktopItems store,
) => showDialog<void>(
  context: context,
  barrierColor: DesktopStyle.barrier,
  builder: (context) => DesktopPanel(
    title: '桌面小组件',
    closeLabel: '关闭小组件面板',
    width: 460,
    height: 600,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in _kinds.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    entry.key == 'clock'
                        ? Icons.schedule
                        : entry.key == 'calendar'
                        ? Icons.calendar_month_outlined
                        : entry.key == 'todo'
                        ? Icons.checklist
                        : Icons.sticky_note_2_outlined,
                    color: const Color(0xFF447DBB),
                  ),
                  title: Text(entry.value),
                  trailing: IconButton(
                    tooltip: '添加${entry.value}',
                    onPressed: store.desktopWidgets.length >= 8
                        ? null
                        : () => store.addWidget(entry.key),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ),
              const Divider(),
              if (store.desktopWidgets.isNotEmpty) ...[
                const Text(
                  '已添加的组件',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                for (final item in store.desktopWidgets)
                  _WidgetManagerEntry(item: item, store: store),
                const Divider(),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示桌面小组件'),
                value: store.widgetsVisible,
                onChanged: store.setWidgetsVisible,
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('锁定小组件位置'),
                value: store.widgetsLocked,
                onChanged: store.setWidgetsLocked,
              ),
              TextButton.icon(
                onPressed: store.canRestoreWidget ? store.restoreWidget : null,
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('恢复上次移除的组件'),
              ),
              Text(
                '${store.desktopWidgets.length}/8',
                style: const TextStyle(fontSize: 12, color: Color(0xFF62718A)),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

/// Local desktop utilities; third-party Android AppWidgets need a separate host.
class DesktopWidgets extends StatelessWidget {
  const DesktopWidgets({super.key, required this.store});
  final DesktopItems store;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: store,
      builder: (context, _) => Stack(
        children: [
          if (store.widgetsVisible)
            for (final item in store.desktopWidgets.where(
              (item) => item['hidden'] != true,
            ))
              _WidgetCard(
                key: ValueKey(item['id']),
                item: item,
                store: store,
                area: constraints.biggest,
                reference: DesktopWidgetLayout.workspace(
                  store.desktopWidgets,
                  constraints.biggest,
                ),
              ),
        ],
      ),
    ),
  );
}

class _WidgetManagerEntry extends StatelessWidget {
  const _WidgetManagerEntry({required this.item, required this.store});
  final Map<String, dynamic> item;
  final DesktopItems store;
  @override
  Widget build(BuildContext context) {
    final id = item['id'] as String;
    final label = item['label'] as String? ?? _kinds[item['kind']]!;
    final hidden = item['hidden'] == true;
    final locked = store.widgetsLocked || item['locked'] == true;
    return ListTile(
      key: ValueKey('widget-manager-$id'),
      contentPadding: EdgeInsets.zero,
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_kinds[item['kind']]} · ${hidden || !store.widgetsVisible ? '已隐藏' : '已显示'}${locked ? ' · 位置已锁定' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '管理$label',
        onSelected: (action) {
          switch (action) {
            case 'visibility':
              store.updateWidget(id, {'hidden': !hidden});
              if (hidden) store.setWidgetsVisible(true);
            case 'lock':
              store.updateWidget(id, {'locked': item['locked'] != true});
            case 'reset':
              store.updateWidget(id, {'left': 24.0, 'top': 24.0});
            case 'duplicate':
              store.duplicateWidget(id);
            case 'remove':
              store.removeWidget(id);
          }
        },
        itemBuilder: (_) => [
          DesktopMenuItem(
            value: 'visibility',
            child: Text(hidden ? '显示此组件' : '隐藏此组件'),
          ),
          DesktopMenuItem(
            value: 'lock',
            enabled: !store.widgetsLocked,
            child: Text(item['locked'] == true ? '解锁此组件' : '锁定此组件'),
          ),
          DesktopMenuItem(
            value: 'reset',
            enabled: !locked,
            child: const Text('移回左上角'),
          ),
          DesktopMenuItem(
            value: 'duplicate',
            enabled: store.desktopWidgets.length < 8,
            child: const Text('复制此组件'),
          ),
          const DesktopMenuItem(value: 'remove', child: Text('移除此组件')),
        ],
      ),
    );
  }
}

class _WidgetCard extends StatefulWidget {
  const _WidgetCard({
    super.key,
    required this.item,
    required this.store,
    required this.area,
    required this.reference,
  });
  final Map<String, dynamic> item;
  final DesktopItems store;
  final Size area;
  final Size reference;
  @override
  State<_WidgetCard> createState() => _WidgetCardState();
}

class _WidgetCardState extends State<_WidgetCard> {
  late final text = TextEditingController(
    text: widget.item['text'] as String? ?? '',
  );
  Offset? dragging;
  Size? resizing;
  bool migrating = false;
  bool gestureCancelled = false;
  Offset? gestureStart, moveStart;
  Size? resizeStart;
  double get scale =>
      DesktopWidgetLayout.scaleFor(widget.area, widget.reference);
  Size get logicalArea => widget.area / scale;

  @override
  void didUpdateWidget(_WidgetCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A resize of the host ends a live gesture preview, without persisting a
    // temporary viewport clamp as the user's preferred desktop position.
    if (widget.area != oldWidget.area ||
        widget.reference != oldWidget.reference ||
        widget.store.widgetsLocked ||
        widget.item['locked'] == true) {
      gestureCancelled = true;
      dragging = null;
      resizing = null;
    }
    final saved = widget.item['text'] as String? ?? '';
    if (text.text != saved) {
      text.value = TextEditingValue(
        text: saved,
        selection: TextSelection.collapsed(offset: saved.length),
      );
    }
  }

  void migrate(Rect rect) {
    if (migrating ||
        widget.area.isEmpty ||
        (widget.item['left'] is num &&
            widget.item['workspaceWidth'] is num &&
            widget.item['workspaceHeight'] is num)) {
      return;
    }
    migrating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      migrating = false;
      if (!mounted) return;
      widget.store.updateWidget(widget.item['id'] as String, {
        if (widget.item['left'] is! num) 'left': rect.left,
        if (widget.item['top'] is! num) 'top': rect.top,
        'workspaceWidth': widget.reference.width,
        'workspaceHeight': widget.reference.height,
      });
    });
  }

  void savePosition(Offset position) {
    final limit = Offset(
      (logicalArea.width - DesktopWidgetLayout.preferredSize(widget.item).width)
          .clamp(0, double.infinity),
      (logicalArea.height -
              DesktopWidgetLayout.preferredSize(widget.item).height)
          .clamp(0, double.infinity),
    );
    widget.store.updateWidget(widget.item['id'] as String, {
      'left': position.dx, 'top': position.dy,
      'workspaceWidth': widget.reference.width,
      'workspaceHeight': widget.reference.height,
      // Keep legacy readers compatible; current readers use logical pixels.
      'x': limit.dx == 0 ? 0.0 : (position.dx / limit.dx).clamp(0, 1),
      'y': limit.dy == 0 ? 0.0 : (position.dy / limit.dy).clamp(0, 1),
    });
  }

  @override
  void dispose() {
    // Text is already copied into the store on every edit; only disk writes debounce.
    text.dispose();
    super.dispose();
  }

  Future<void> menu(Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        DesktopMenuItem(
          value: 'lock',
          child: Text(widget.item['locked'] == true ? '解锁组件' : '锁定组件'),
        ),
        const DesktopMenuItem(value: 'rename', child: Text('重命名组件')),
        DesktopMenuItem(
          value: 'duplicate',
          enabled: widget.store.desktopWidgets.length < 8,
          child: const Text('复制组件'),
        ),
        const DesktopMenuItem(value: 'front', child: Text('置于其他组件上方')),
        DesktopMenuItem(
          value: 'size',
          enabled: !widget.store.widgetsLocked && widget.item['locked'] != true,
          child: Text(widget.item['large'] == true ? '缩小组件' : '放大组件'),
        ),
        const DesktopMenuItem(value: 'remove', child: Text('移除组件')),
      ],
    );
    if (!mounted) return;
    final id = widget.item['id'] as String;
    if (action == 'lock') {
      widget.store.updateWidget(id, {'locked': widget.item['locked'] != true});
    }
    if (action == 'duplicate') widget.store.duplicateWidget(id);
    if (action == 'front') widget.store.raiseWidget(id);
    if (action == 'rename') {
      final controller = TextEditingController(
        text: widget.item['label'] as String? ?? _kinds[widget.item['kind']]!,
      );
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重命名组件'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 40,
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      controller.dispose();
      if (mounted && name != null && name.trim().isNotEmpty) {
        widget.store.updateWidget(id, {'label': name.trim()});
      }
    }
    if (!mounted) return;
    if (action == 'size') {
      final next = Map<String, dynamic>.from(widget.item)
        ..remove('width')
        ..remove('height');
      next['large'] = widget.item['large'] != true;
      final size = DesktopWidgetLayout.preferredSize(next);
      widget.store.updateWidget(widget.item['id'] as String, {
        'large': widget.item['large'] != true,
        'width': size.width,
        'height': size.height,
      });
    }
    if (action == 'remove') {
      widget.store.removeWidget(widget.item['id'] as String);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: const Text('已移除小组件'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: widget.store.restoreWidget,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final kind = item['kind'] as String;
    final locked = widget.store.widgetsLocked || item['locked'] == true;
    final size = resizing ?? DesktopWidgetLayout.preferredSize(item);
    final logicalRect = DesktopWidgetLayout.fit(
      dragging ?? DesktopWidgetLayout.preferredPosition(item, widget.reference),
      size,
      logicalArea,
    );
    migrate(logicalRect);
    final rect = DesktopWidgetLayout.scaleRect(logicalRect, scale);
    final position = logicalRect.topLeft;
    return Positioned(
      key: ValueKey('widget-bounds-${item['id']}'),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Theme(
        data: DesktopStyle.theme(context),
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: logicalRect.width.clamp(240, double.infinity),
            height: logicalRect.height.clamp(
              kind == 'clock' ? 160 : 180,
              double.infinity,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: kind == 'note'
                        ? const Color(0xE8FFF8DE)
                        : const Color(0xC6F8FAFC),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: const Color(0x70FFFFFF),
                      width: 0.8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x18000000),
                        blurRadius: 20,
                        spreadRadius: -2,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                  Column(
                    children: [
                      GestureDetector(
                        key: ValueKey('widget-drag-${item['id']}'),
                        behavior: HitTestBehavior.opaque,
                        onSecondaryTapUp: (event) => menu(event.globalPosition),
                        onPanUpdate: locked
                            ? null
                            : (event) {
                                if (gestureCancelled) return;
                                setState(
                                  () => dragging =
                                      moveStart! +
                                      (event.globalPosition - gestureStart!) /
                                          scale,
                                );
                              },
                        onPanStart: locked
                            ? null
                            : (event) {
                                gestureCancelled = false;
                                gestureStart = event.globalPosition;
                                moveStart = position;
                                widget.store.raiseWidget(item['id'] as String);
                              },
                        onPanEnd: locked
                            ? null
                            : (_) {
                                if (gestureCancelled) return;
                                final end = dragging ?? position;
                                savePosition(
                                  DesktopWidgetLayout.fit(
                                    end,
                                    size,
                                    logicalArea,
                                  ).topLeft,
                                );
                                setState(() => dragging = null);
                              },
                        onPanCancel: () => setState(() => dragging = null),
                        child: MouseRegion(
                          cursor: locked
                              ? SystemMouseCursors.basic
                              : SystemMouseCursors.move,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 16, right: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item['label'] as String? ?? _kinds[kind]!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF62718A),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '组件选项',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    final box =
                                        context.findRenderObject() as RenderBox;
                                    menu(
                                      box.localToGlobal(const Offset(24, 28)),
                                    );
                                  },
                                  icon: const Icon(Icons.more_horiz, size: 18),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: kind == 'clock'
                            ? const Align(
                                alignment: Alignment.centerLeft,
                                child: DesktopClock(card: true),
                              )
                            : kind == 'calendar'
                            ? LayoutBuilder(
                                builder: (context, constraints) =>
                                    SingleChildScrollView(
                                      child: SizedBox(
                                        height: constraints.maxHeight.clamp(
                                          340,
                                          double.infinity,
                                        ),
                                        child: const DesktopCalendar(),
                                      ),
                                    ),
                              )
                            : kind == 'todo'
                            ? DesktopTodo(item: item, store: widget.store)
                            : Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  14,
                                ),
                                child: TextField(
                                  controller: text,
                                  expands: true,
                                  minLines: null,
                                  maxLines: null,
                                  maxLength: 8000,
                                  textAlignVertical: TextAlignVertical.top,
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    hintText: '记点什么…',
                                    counterText: '',
                                  ),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.6,
                                    color: Color(0xFF544A2D),
                                  ),
                                  onChanged: (_) {
                                    widget.store.setWidgetText(
                                      item['id'] as String,
                                      text.text,
                                    );
                                  },
                                ),
                              ),
                      ),
                    ],
                  ),
                  if (!locked)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      width: 24,
                      height: 24,
                      child: Tooltip(
                        message: '拖动调整组件大小',
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeDownRight,
                          child: GestureDetector(
                            key: ValueKey('widget-resize-${item['id']}'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (event) {
                              gestureCancelled = false;
                              gestureStart = event.globalPosition;
                              resizeStart = logicalRect.size;
                              widget.store.raiseWidget(item['id'] as String);
                              setState(() => resizing = logicalRect.size);
                            },
                            onPanUpdate: (event) {
                              if (gestureCancelled || resizing == null) return;
                              final delta =
                                  (event.globalPosition - gestureStart!) /
                                  scale;
                              setState(
                                () => resizing = Size(
                                  (resizeStart!.width + delta.dx).clamp(
                                    240,
                                    (logicalArea.width - position.dx).clamp(
                                      240,
                                      640,
                                    ),
                                  ),
                                  (resizeStart!.height + delta.dy).clamp(
                                    kind == 'clock' ? 140 : 180,
                                    (logicalArea.height - position.dy).clamp(
                                      kind == 'clock' ? 140 : 180,
                                      720,
                                    ),
                                  ),
                                ),
                              );
                            },
                            onPanEnd: (_) {
                              if (gestureCancelled) return;
                              final end = resizing;
                              if (end != null) {
                                widget.store.updateWidget(
                                  item['id'] as String,
                                  {
                                    'width': end.width,
                                    'height': end.height,
                                    'workspaceWidth': widget.reference.width,
                                    'workspaceHeight': widget.reference.height,
                                  },
                                );
                              }
                              setState(() => resizing = null);
                            },
                            onPanCancel: () => setState(() => resizing = null),
                            child: const Align(
                              alignment: Alignment.bottomRight,
                              child: Padding(
                                padding: EdgeInsets.all(3),
                                child: Icon(
                                  Icons.south_east,
                                  size: 12,
                                  color: Color(0xFF8190A5),
                                ),
                              ),
                            ),
                          ),
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
    );
  }
}
