import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../desktop_items.dart';
import 'phone_app_icon.dart';
import 'desktop_style.dart';
import 'desktop_settings_dialog.dart';

/// Persistent app shortcuts; Android still owns the application UI.
class DesktopShortcuts extends StatefulWidget {
  const DesktopShortcuts({
    super.key,
    required this.apps,
    required this.onLaunch,
    this.store,
    this.onRefresh,
    this.onWidgets,
  });
  final List<Map<String, dynamic>> apps;
  final ValueChanged<String> onLaunch;
  final DesktopItems? store;
  final VoidCallback? onRefresh, onWidgets;
  @override
  State<DesktopShortcuts> createState() => _DesktopShortcutsState();
}

class _DesktopShortcutsState extends State<DesktopShortcuts> {
  late final DesktopItems store = widget.store ?? DesktopItems();
  @override
  void initState() {
    super.initState();
    store.seed(widget.apps);
  }

  @override
  void didUpdateWidget(DesktopShortcuts oldWidget) {
    super.didUpdateWidget(oldWidget);
    store.seed(widget.apps);
  }

  @override
  void dispose() {
    if (widget.store == null) store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ItemsView(
    store: store,
    apps: widget.apps,
    onLaunch: widget.onLaunch,
    onRefresh: widget.onRefresh,
    onWidgets: widget.onWidgets,
  );
}

class _ItemsView extends StatefulWidget {
  const _ItemsView({
    required this.store,
    required this.apps,
    required this.onLaunch,
    this.parent,
    this.onRefresh,
    this.onWidgets,
  });
  final DesktopItems store;
  final List<Map<String, dynamic>> apps;
  final ValueChanged<String> onLaunch;
  final String? parent;
  final VoidCallback? onRefresh, onWidgets;
  @override
  State<_ItemsView> createState() => _ItemsViewState();
}

class _ItemsViewState extends State<_ItemsView> {
  final focus = FocusNode();
  final selected = <String>{};
  final areaKey = GlobalKey();
  final itemKeys = <String, GlobalKey>{};
  final scroll = ScrollController();
  final boxSelection = ValueNotifier<Rect?>(null);
  final selectionBefore = <String>{};
  int? selectionPointer;
  Offset? selectionStart;
  Offset? selectionEnd;
  double selectionScroll = 0;
  bool selectionToggle = false, selectionAdd = false;
  String? selectionAnchorBefore;
  Timer? autoScroll;
  String? anchor;
  String? clickedItem;
  int? clickPointer;
  Offset? clickStart;
  bool plainClick = false;
  String searchPrefix = '';
  Timer? searchReset;
  @override
  void dispose() {
    focus.dispose();
    autoScroll?.cancel();
    scroll.dispose();
    boxSelection.dispose();
    searchReset?.cancel();
    super.dispose();
  }

  void select(DesktopItem item) {
    if (!mounted || widget.store.byId(item.id) == null) return;
    focus.requestFocus();
    final keyboard = HardwareKeyboard.instance;
    final entries = widget.store.children(widget.parent);
    setState(() {
      if (keyboard.isShiftPressed && anchor != null) {
        final a = entries.indexWhere((entry) => entry.id == anchor),
            b = entries.indexOf(item);
        if (a >= 0 && b >= 0) {
          selected.addAll(
            entries
                .sublist(a < b ? a : b, (a > b ? a : b) + 1)
                .map((entry) => entry.id),
          );
          return;
        }
      }
      if (keyboard.isControlPressed) {
        if (!selected.add(item.id)) selected.remove(item.id);
      } else {
        selected
          ..clear()
          ..add(item.id);
      }
      anchor = item.id;
    });
  }

  RenderBox? get area =>
      areaKey.currentContext?.findRenderObject() as RenderBox?;

  Map<String, Rect> iconRects() {
    final container = area;
    if (container == null) return {};
    // Include virtualized cells too, so edge scrolling keeps earlier hits.
    final horizontal = widget.parent == null;
    final crossExtent =
        (horizontal ? container.size.height : container.size.width) - 32;
    final count = (crossExtent / 104).floor().clamp(1, 100);
    final crossSize = crossExtent / count;
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final entries = widget.store.children(widget.parent);
    return {
      for (var index = 0; index < entries.length; index++)
        entries[index].id: Rect.fromLTWH(
          16 +
              (horizontal
                  ? index ~/ count * 104 - offset + 4
                  : index % count * crossSize + (crossSize - 96) / 2),
          16 +
              (horizontal
                  ? index % count * crossSize + (crossSize - 96) / 2
                  : index ~/ count * 104 - offset + 4),
          96,
          96,
        ),
    };
  }

  void selectionDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton) return;
    final point = event.localPosition;
    if (iconRects().values.any((rect) => rect.contains(point))) return;
    focus.requestFocus();
    if (event.kind != PointerDeviceKind.mouse) {
      setState(selected.clear);
      return;
    }
    selectionPointer = event.pointer;
    selectionStart = selectionEnd = point;
    selectionScroll = scroll.hasClients ? scroll.offset : 0;
    selectionBefore
      ..clear()
      ..addAll(selected);
    selectionAnchorBefore = anchor;
    selectionToggle = HardwareKeyboard.instance.isControlPressed;
    selectionAdd = HardwareKeyboard.instance.isShiftPressed;
    if (!selectionToggle && !selectionAdd) setState(selected.clear);
  }

  void selectionMove(PointerMoveEvent event) {
    if (event.pointer != selectionPointer || selectionStart == null) return;
    selectionEnd = event.localPosition;
    if ((selectionEnd! - selectionStart!).distance < 4 &&
        boxSelection.value == null) {
      return;
    }
    updateBox();
    autoScroll ??= Timer.periodic(const Duration(milliseconds: 32), (_) {
      final bounds = area;
      if (bounds == null || selectionEnd == null || !scroll.hasClients) return;
      final horizontal = widget.parent == null;
      final position = horizontal ? selectionEnd!.dx : selectionEnd!.dy;
      final extent = horizontal ? bounds.size.width : bounds.size.height;
      final delta = position < 24
          ? -14.0
          : position > extent - 24
          ? 14.0
          : 0.0;
      if (delta == 0) return;
      final next = (scroll.offset + delta).clamp(
        0.0,
        scroll.position.maxScrollExtent,
      );
      if (next == scroll.offset) return;
      scroll.jumpTo(next);
      updateBox();
    });
  }

  void updateBox() {
    final bounds = area;
    if (bounds == null || selectionStart == null || selectionEnd == null) {
      return;
    }
    final scrolled = (scroll.hasClients ? scroll.offset : 0) - selectionScroll;
    final start =
        selectionStart! -
        (widget.parent == null ? Offset(scrolled, 0) : Offset(0, scrolled));
    final rect = Rect.fromPoints(start, selectionEnd!);
    boxSelection.value = rect.intersect(Offset.zero & bounds.size);
    final hits = iconRects().entries
        .where((entry) => entry.value.overlaps(rect))
        .map((entry) => entry.key)
        .toSet();
    final next = selectionToggle
        ? {
            ...selectionBefore.difference(hits),
            ...hits.difference(selectionBefore),
          }
        : selectionAdd
        ? {...selectionBefore, ...hits}
        : hits;
    if (next.length != selected.length || !selected.containsAll(next)) {
      setState(() {
        selected
          ..clear()
          ..addAll(next);
        anchor = next.isEmpty ? null : next.last;
      });
    }
  }

  void endSelection({bool cancel = false}) {
    if (selectionPointer == null) return;
    autoScroll?.cancel();
    autoScroll = null;
    if (cancel) {
      setState(() {
        selected
          ..clear()
          ..addAll(selectionBefore);
        anchor = selectionAnchorBefore;
      });
    }
    selectionPointer = null;
    selectionStart = selectionEnd = null;
    boxSelection.value = null;
  }

  List<String> dragIds(String id) =>
      selected.contains(id) ? selected.toList() : [id];

  Future<void> open(DesktopItem item) async {
    if (!item.isFolder) {
      widget.onLaunch(item.component!);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFFF8F9FC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: 600,
          height: 440,
          child: Column(
            children: [
              ListenableBuilder(
                listenable: widget.store,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 8, 4),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.folder_rounded,
                        color: Color(0xFFE9B64F),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.store.byId(item.id)?.label ?? item.label,
                          style: const TextStyle(
                            color: Color(0xFF242B36),
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭文件夹',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.close,
                          color: Color(0xFF515968),
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _ItemsView(
                  store: widget.store,
                  apps: widget.apps,
                  onLaunch: (component) {
                    Navigator.pop(context);
                    widget.onLaunch(component);
                  },
                  parent: item.id,
                  onRefresh: widget.onRefresh,
                  onWidgets: widget.onWidgets,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) focus.requestFocus();
  }

  Future<void> rename(DesktopItem item) async {
    final controller = TextEditingController(text: item.label);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: item.label.length,
    );
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
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
    if (label != null) widget.store.rename(item.id, label);
    if (mounted) focus.requestFocus();
  }

  void newFolder() {
    final item = widget.store.createFolder(parent: widget.parent);
    setState(() {
      selected
        ..clear()
        ..add(item.id);
      anchor = item.id;
    });
    rename(item);
  }

  PopupMenuEntry<String> entry(
    String value,
    String label,
    IconData icon, {
    bool enabled = true,
  }) => DesktopMenuItem(
    value: value,
    enabled: enabled,
    height: 36,
    child: Row(
      children: [
        Icon(icon, size: 17, color: const Color(0xFF566171)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Color(0xFF293342)),
          ),
        ),
      ],
    ),
  );

  Future<void> menu(Offset position, [DesktopItem? item]) async {
    focus.requestFocus();
    if (item != null && !selected.contains(item.id)) {
      setState(() {
        selected
          ..clear()
          ..add(item.id);
        anchor = item.id;
      });
    }
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final folders = widget.store.items
        .where(
          (folder) =>
              folder.isFolder &&
              folder.id != item?.id &&
              folder.id != item?.parent &&
              selected.every((id) => widget.store.canMove(id, folder.id)),
        )
        .toList();
    final choice = await showMenu<String>(
      context: context,
      color: const Color(0xFFF9FAFC),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (item != null) ...[
          entry(
            'open',
            '打开',
            item.isFolder ? Icons.folder_open : Icons.open_in_new,
          ),
          if (selected.length == 1)
            entry('rename', '重命名   F2', Icons.drive_file_rename_outline),
          if (!item.isFolder && selected.length == 1)
            entry(
              'pinDock',
              widget.store.isDockPinned(item.component!)
                  ? '从 Dock 取消固定'
                  : '固定到 Dock',
              Icons.push_pin_outlined,
              enabled:
                  widget.store.isDockPinned(item.component!) ||
                  widget.store.dockApps.length < 12,
            ),
          entry('copy', '复制快捷方式   Ctrl+C', Icons.copy_outlined),
          entry('cut', '剪切快捷方式   Ctrl+X', Icons.content_cut),
          if (item.parent != null)
            entry('root', '移到桌面', Icons.desktop_windows_outlined),
          for (final folder in folders)
            entry(
              'move:${folder.id}',
              '移到「${folder.label}」',
              Icons.drive_file_move_outline,
            ),
          const PopupMenuDivider(),
          entry(
            'remove',
            item.isFolder ? '解散文件夹（保留快捷方式）' : '删除快捷方式   Delete',
            Icons.delete_outline,
          ),
          entry('properties', '属性   Alt+Enter', Icons.info_outline),
        ] else ...[
          entry(
            'undo',
            '撤销桌面操作   Ctrl+Z',
            Icons.undo,
            enabled: widget.store.canUndoDesktop,
          ),
          entry(
            'redo',
            '重做桌面操作   Ctrl+Y',
            Icons.redo,
            enabled: widget.store.canRedoDesktop,
          ),
          const PopupMenuDivider(),
          entry(
            'folder',
            '新建文件夹   Ctrl+Shift+N',
            Icons.create_new_folder_outlined,
          ),
          entry('sort', '按名称排列', Icons.sort_by_alpha),
          if (widget.store.canPaste)
            entry('paste', '粘贴快捷方式   Ctrl+V', Icons.content_paste),
          entry('selectAll', '全选   Ctrl+A', Icons.select_all),
          if (widget.parent == null && widget.onWidgets != null)
            entry('widgets', '桌面小组件', Icons.widgets_outlined),
          if (widget.parent == null && widget.store.desktopWidgets.isNotEmpty)
            entry(
              'toggleWidgets',
              widget.store.widgetsVisible ? '隐藏桌面小组件' : '显示桌面小组件',
              Icons.widgets_outlined,
            ),
          entry('refresh', '刷新桌面', Icons.refresh),
          if (widget.parent == null) ...[
            const PopupMenuDivider(),
            entry('settings', '桌面与外观设置...', Icons.palette_outlined),
          ],
        ],
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'undo':
        widget.store.undoDesktop();
      case 'redo':
        widget.store.redoDesktop();
      case 'toggleWidgets':
        widget.store.setWidgetsVisible(!widget.store.widgetsVisible);
      case 'open':
        await open(item!);
      case 'rename':
        await rename(item!);
      case 'pinDock':
        final component = item!.component!;
        if (widget.store.isDockPinned(component)) {
          widget.store.unpinDockApp(component);
        } else {
          widget.store.pinDockApp(component, item.label);
        }
      case 'copy':
        widget.store.copySelection(selected);
      case 'cut':
        widget.store.copySelection(selected, cut: true);
      case 'paste':
        widget.store.paste(widget.parent);
      case 'selectAll':
        setState(
          () => selected.addAll(
            widget.store.children(widget.parent).map((item) => item.id),
          ),
        );
      case 'widgets':
        widget.onWidgets?.call();
      case 'properties':
        properties();
      case 'root':
        widget.store.moveMany(selected.toList(), null);
      case 'remove':
        widget.store.removeMany(selected);
        setState(selected.clear);
      case 'folder':
        newFolder();
      case 'sort':
        widget.store.sortByName(widget.parent);
      case 'settings':
        showDesktopSettings(context, widget.store);
      case 'refresh':
        widget.onRefresh?.call();
        setState(() {});
      default:
        if (choice.startsWith('move:')) {
          widget.store.moveMany(selected.toList(), choice.substring(5));
        }
    }
  }

  Future<void> properties() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(selected.length == 1 ? '快捷方式属性' : '${selected.length} 个项目'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: SelectableText(
            [
              for (final id in selected)
                if (widget.store.byId(id) case final DesktopItem item)
                  '${item.label}\n${item.isFolder ? '文件夹 · ${widget.store.children(id).length} 个项目' : item.component}',
            ].join('\n\n'),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  KeyEventResult key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.f5) {
      widget.onRefresh?.call();
      setState(() {});
      return KeyEventResult.handled;
    }
    if (keyboard.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        selected.isNotEmpty) {
      properties();
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ ||
          event.logicalKey == LogicalKeyboardKey.keyY) {
        if (event.logicalKey == LogicalKeyboardKey.keyY ||
            keyboard.isShiftPressed) {
          widget.store.redoDesktop();
        } else {
          widget.store.undoDesktop();
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyC ||
          event.logicalKey == LogicalKeyboardKey.keyX) {
        widget.store.copySelection(
          selected,
          cut: event.logicalKey == LogicalKeyboardKey.keyX,
        );
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        widget.store.paste(widget.parent);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        selectionPointer != null) {
      endSelection(cancel: true);
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed &&
        keyboard.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyN) {
      newFolder();
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyA) {
      setState(
        () => selected.addAll(
          widget.store.children(widget.parent).map((item) => item.id),
        ),
      );
      return KeyEventResult.handled;
    }
    final item = selected.length == 1
        ? widget.store.byId(selected.first)
        : null;
    if (event.logicalKey == LogicalKeyboardKey.contextMenu ||
        (keyboard.isShiftPressed &&
            event.logicalKey == LogicalKeyboardKey.f10)) {
      final box = area;
      if (box != null) {
        final target = selected.contains(anchor)
            ? widget.store.byId(anchor)
            : selected.isEmpty
            ? null
            : widget.store.byId(selected.first);
        final rect = iconRects()[target?.id];
        menu(
          box.localToGlobal(rect?.bottomRight ?? const Offset(24, 24)),
          target,
        );
      }
      return KeyEventResult.handled;
    }
    const arrows = [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
    ];
    if (arrows.contains(event.logicalKey)) {
      final entries = widget.store.children(widget.parent);
      if (entries.isEmpty) return KeyEventResult.handled;
      final bounds = area;
      final cross =
          (((widget.parent == null
                      ? bounds?.size.height
                      : bounds?.size.width) ??
                  104) -
              32) ~/
          104;
      final stride = cross.clamp(1, 100);
      final current = entries.indexWhere((entry) => entry.id == anchor);
      final horizontal = widget.parent == null;
      final delta = event.logicalKey == LogicalKeyboardKey.arrowLeft
          ? -(horizontal ? stride : 1)
          : event.logicalKey == LogicalKeyboardKey.arrowRight
          ? (horizontal ? stride : 1)
          : event.logicalKey == LogicalKeyboardKey.arrowUp
          ? -(horizontal ? 1 : stride)
          : (horizontal ? 1 : stride);
      final index = event.logicalKey == LogicalKeyboardKey.home
          ? 0
          : event.logicalKey == LogicalKeyboardKey.end
          ? entries.length - 1
          : current < 0
          ? 0
          : (current + delta).clamp(0, entries.length - 1);
      select(entries[index]);
      final target = itemKeys[entries[index].id]?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: .5);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.f2 && item != null) {
      rename(item);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && item != null) {
      open(item);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      widget.store.removeMany(selected);
      setState(selected.clear);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(selected.clear);
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (!keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        character != null &&
        character.isNotEmpty &&
        character.codeUnitAt(0) >= 32) {
      searchReset?.cancel();
      final value = character.toLowerCase();
      searchPrefix += value;
      final cycle = searchPrefix.split('').every((part) => part == value);
      final prefix = cycle ? value : searchPrefix;
      final entries = widget.store.children(widget.parent);
      final matches = entries
          .where((item) => item.label.toLowerCase().startsWith(prefix))
          .toList();
      if (matches.isNotEmpty) {
        final current = matches.indexWhere((item) => item.id == anchor);
        final item = cycle
            ? matches[(current + 1) % matches.length]
            : matches.first;
        select(item);
        final target = itemKeys[item.id]?.currentContext;
        if (target != null) Scrollable.ensureVisible(target, alignment: .5);
      }
      searchReset = Timer(
        const Duration(milliseconds: 850),
        () => searchPrefix = '',
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget tile(DesktopItem item, {bool target = false, bool keyed = true}) {
    final catalog = widget.apps.where(
      (app) => app['component'] == item.component,
    );
    final isSelected = selected.contains(item.id) || target;
    return Semantics(
      key: keyed ? ValueKey('desktop-item-${item.id}') : null,
      label: item.label,
      selected: isSelected,
      child: Container(
        key: keyed ? itemKeys.putIfAbsent(item.id, GlobalKey.new) : null,
        width: 96,
        height: 96,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0x35478ED9) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: isSelected ? const Color(0x777DADE7) : Colors.transparent,
          ),
        ),
        child: Column(
          children: [
            if (item.isFolder)
              const Icon(
                Icons.folder_rounded,
                color: Color(0xFFF0C366),
                size: 44,
              )
            else
              PhoneAppIcon(
                encoded: catalog.isEmpty
                    ? null
                    : catalog.first['icon'] as String?,
                size: 42,
              ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                item.label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  color: widget.parent == null
                      ? Colors.white
                      : const Color(0xFF293342),
                  fontWeight: widget.parent == null ? FontWeight.w500 : FontWeight.normal,
                  shadows: widget.parent == null
                      ? const [
                          Shadow(
                            color: Color(0xDD000000),
                            blurRadius: 4,
                            offset: Offset(0, 1.5),
                          ),
                          Shadow(
                            color: Color(0x99000000),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget icon(DesktopItem item) => DragTarget<List<String>>(
    onWillAcceptWithDetails: (details) =>
        !details.data.contains(item.id) &&
        details.data.every(
          (id) =>
              widget.store.canMove(id, item.isFolder ? item.id : widget.parent),
        ),
    onAcceptWithDetails: (details) => widget.store.moveMany(
      details.data,
      item.isFolder ? item.id : widget.parent,
      before: item.isFolder ? null : item.id,
    ),
    builder: (context, candidates, rejected) => Draggable<List<String>>(
      data: dragIds(item.id),
      onDragStarted: () {
        focus.requestFocus();
        if (!selected.contains(item.id)) {
          setState(() {
            selected
              ..clear()
              ..add(item.id);
            anchor = item.id;
          });
        }
      },
      feedback: Material(
        color: Colors.transparent,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(opacity: .85, child: tile(item, keyed: false)),
            if (dragIds(item.id).length > 1)
              Positioned(
                right: 2,
                top: 2,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: const Color(0xFF3785D8),
                  child: Text(
                    '${dragIds(item.id).length}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
      childWhenDragging: Opacity(opacity: .3, child: tile(item, keyed: false)),
      child: Tooltip(
        message: item.label,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: Listener(
            onPointerDown: (event) {
              if (event.buttons == kMiddleMouseButton && !item.isFolder) {
                open(item);
                return;
              }
              if (event.buttons != kPrimaryMouseButton) return;
              clickedItem = item.id;
              clickPointer = event.pointer;
              clickStart = event.position;
              plainClick =
                  !HardwareKeyboard.instance.isControlPressed &&
                  !HardwareKeyboard.instance.isShiftPressed;
              if (!selected.contains(item.id) ||
                  HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isShiftPressed) {
                select(item);
              } else {
                focus.requestFocus();
              }
            },
            onPointerMove: (event) {
              if (event.pointer == clickPointer &&
                  clickStart != null &&
                  (event.position - clickStart!).distance > 4) {
                clickedItem = null;
              }
            },
            onPointerUp: (event) {
              if (event.pointer == clickPointer &&
                  clickedItem == item.id &&
                  plainClick) {
                select(item);
              }
              clickedItem = null;
            },
            onPointerCancel: (_) => clickedItem = null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => open(item),
              onSecondaryTapUp: (event) => menu(event.globalPosition, item),
              child: tile(item, target: candidates.isNotEmpty),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: key,
    child: ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final entries = widget.store.children(widget.parent);
        selected.retainAll(entries.map((item) => item.id));
        if (!selected.contains(anchor)) anchor = null;
        return DragTarget<List<String>>(
          onWillAcceptWithDetails: (details) =>
              details.data.every(
                (id) => widget.store.canMove(id, widget.parent),
              ) &&
              details.data.any(
                (id) => widget.store.byId(id)?.parent != widget.parent,
              ),
          onAcceptWithDetails: (details) =>
              widget.store.moveMany(details.data, widget.parent),
          builder: (context, candidates, rejected) => Listener(
            key: areaKey,
            behavior: HitTestBehavior.opaque,
            onPointerDown: selectionDown,
            onPointerMove: selectionMove,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent &&
                  widget.parent == null &&
                  scroll.hasClients &&
                  scroll.position.maxScrollExtent > 0) {
                GestureBinding.instance.pointerSignalResolver.register(event, (
                  _,
                ) {
                  scroll.jumpTo(
                    (scroll.offset +
                            event.scrollDelta.dy +
                            event.scrollDelta.dx)
                        .clamp(0, scroll.position.maxScrollExtent),
                  );
                });
              }
            },
            onPointerUp: (event) {
              if (event.pointer == selectionPointer) endSelection();
            },
            onPointerCancel: (event) {
              if (event.pointer == selectionPointer) endSelection(cancel: true);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) {},
                  onSecondaryTapUp: (event) => menu(event.globalPosition),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (entries.isEmpty && widget.parent != null) {
                          return const Center(
                            child: Text(
                              '将桌面快捷方式拖到此文件夹',
                              style: TextStyle(
                                color: Color(0xFF7D8796),
                                fontSize: 13,
                              ),
                            ),
                          );
                        }
                        final desktop = widget.parent == null;
                        return GridView.builder(
                          controller: scroll,
                          scrollDirection: desktop
                              ? Axis.horizontal
                              : Axis.vertical,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount:
                                    ((desktop
                                                ? constraints.maxHeight
                                                : constraints.maxWidth) /
                                            104)
                                        .floor()
                                        .clamp(1, 100),
                                mainAxisExtent: 104,
                              ),
                          itemCount: entries.length,
                          itemBuilder: (context, index) => Center(
                            key: ValueKey(entries[index].id),
                            child: icon(entries[index]),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                IgnorePointer(
                  child: ValueListenableBuilder<Rect?>(
                    valueListenable: boxSelection,
                    builder: (context, rect, _) => Stack(
                      children: [
                        if (rect != null && !rect.isEmpty)
                          Positioned.fromRect(
                            rect: rect,
                            child: DecoratedBox(
                              key: const ValueKey('desktop-selection-box'),
                              decoration: BoxDecoration(
                                color: const Color(0x303789DF),
                                border: Border.all(
                                  color: const Color(0xFF80B8F6),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
