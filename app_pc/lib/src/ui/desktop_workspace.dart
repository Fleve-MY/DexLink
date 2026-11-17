import 'dart:async';

import 'package:dex_link/dex_link.dart';
import 'package:flutter/material.dart';

import '../dex_session.dart';
import '../desktop_items.dart';
import 'desktop_app_drawer.dart';
import 'desktop_task_overview.dart';
import 'dock_item.dart';
import 'desktop_dock.dart';
import 'phone_app_icon.dart';
import 'desktop_style.dart';

/// The tabs represent Android tasks on this session's independent display.
class DesktopWorkspace extends StatefulWidget {
  const DesktopWorkspace({
    super.key,
    required this.session,
    required this.onProblem,
    required this.onInteraction,
    this.onState,
    this.onAddShortcut,
    this.onWidgets,
    this.layoutForApp,
    this.items,
  });
  final DexSession session;
  final ValueChanged<String> onProblem;
  final VoidCallback onInteraction;
  final ValueChanged<Map<String, dynamic>>? onState;
  final ValueChanged<Map<String, dynamic>>? onAddShortcut;
  final VoidCallback? onWidgets;
  final String Function(String component)? layoutForApp;
  final DesktopItems? items;

  @override
  State<DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<DesktopWorkspace> {
  StreamSubscription<DeviceMessage>? _messages;
  Timer? _poll;
  Timer? _timeout;
  bool _pending = false;
  final List<({String action, Map<String, Object> values})> _queued = [];
  bool _freeform = false;
  List<Map<String, dynamic>> _apps = [];
  List<Map<String, dynamic>> _tasks = [];
  final _iconAttempts = <String>{};
  bool _iconBatches = false;
  final _changes = ValueNotifier(0);

  void _preferencesChanged() {
    if (!mounted) return;
    setState(() {});
    _changes.value++;
  }

  @override
  void didUpdateWidget(DesktopWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      oldWidget.items?.removeListener(_preferencesChanged);
      widget.items?.addListener(_preferencesChanged);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.items?.addListener(_preferencesChanged);
    _messages = widget.session.deviceMessages.listen((message) {
      if (!mounted || message is! DesktopMessage) return;
      _timeout?.cancel();
      final data = message.data;
      setState(() {
        _pending = false;
        _freeform = data['freeform'] == true;
        if (data['apps'] case final List apps) {
          _apps = apps.whereType<Map<String, dynamic>>().toList();
          _iconAttempts.clear();
          _iconBatches = data['iconBatches'] == true;
        }
        if (data['icons'] case final List icons) {
          for (final row in icons.whereType<Map<String, dynamic>>()) {
            for (final app in _apps) {
              if (app['component'] == row['component'] &&
                  row['icon'] is String) {
                app['icon'] = row['icon'];
              }
            }
          }
        }
        if (data['tasks'] case final List tasks) {
          final incoming = tasks.whereType<Map<String, dynamic>>().toList();
          final order = _tasks.map((task) => task['id']).toList();
          incoming.sort((a, b) {
            final ai = order.indexOf(a['id']), bi = order.indexOf(b['id']);
            if (ai < 0 && bi < 0) return 0;
            return (ai < 0 ? order.length : ai).compareTo(
              bi < 0 ? order.length : bi,
            );
          });
          _tasks = incoming;
        }
      });
      widget.onState?.call({...data, if (data['icons'] is List) 'apps': _apps});
      _changes.value++;
      if (data['ok'] != true) {
        widget.onProblem('桌面操作失败：${data['error'] ?? '手机未完成操作'}');
      } else if (data['warning'] case final String warning) {
        widget.onProblem(warning);
      }
      _sendNext();
      _fetchIcons();
    });
    _request('apps');
    _poll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _request('state'),
    );
  }

  void _fetchIcons() {
    if (_pending || _queued.isNotEmpty || !_iconBatches) return;
    final missing = _apps
        .where(
          (app) =>
              app['icon'] == null && !_iconAttempts.contains(app['component']),
        )
        .take(16)
        .map((app) => app['component'] as String)
        .toList();
    if (missing.isEmpty) return;
    _iconAttempts.addAll(missing);
    _request('icons', values: {'components': missing});
  }

  bool _request(String action, {Map<String, Object> values = const {}}) {
    if (!widget.session.controlRepliesAvailable) return false;
    if (_pending) {
      if (action == 'state') return false;
      if (_queued.length >= 8) {
        widget.onProblem('桌面操作过于频繁，请稍后重试');
        return false;
      }
      _queued.add((action: action, values: values));
      return true;
    }
    _pending = true;
    widget.session.send(ControlMessages.desktop({'action': action, ...values}));
    _timeout = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      setState(() => _pending = false);
      widget.onProblem('手机未响应桌面操作，请检查连接');
      _sendNext();
    });
    return true;
  }

  void _sendNext() {
    if (!mounted || _pending || _queued.isEmpty) return;
    final next = _queued.removeAt(0);
    _request(next.action, values: next.values);
  }

  void _action(String action, [Map<String, Object> values = const {}]) {
    _request(
      action,
      values: {
        ...values,
        if (_tasks.any((task) => task['kind'] == 'appWindow'))
          'clientViewport': true,
      },
    );
    widget.onInteraction();
  }

  Future<void> _drawer() async {
    if (_apps.isEmpty) {
      _request('apps');
      widget.onProblem('正在读取手机应用列表，请稍后重试');
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      barrierColor: DesktopStyle.barrier,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Duration(milliseconds: 220),
              reverseDuration: Duration(milliseconds: 160),
              curve: Cubic(.23, 1, .32, 1),
            ),
      builder: (_) => ListenableBuilder(
        listenable: _changes,
        builder: (_, _) => DesktopAppDrawer(
          apps: _apps,
          items: widget.items,
          onAddShortcut: widget.onAddShortcut,
          onRefresh: () {
            if (!_pending) _request('apps');
          },
          onProblem: widget.onProblem,
        ),
      ),
    );
    if (!mounted) return;
    if (selected != null) {
      _launch(selected);
    }
    widget.onInteraction();
  }

  @override
  void dispose() {
    widget.items?.removeListener(_preferencesChanged);
    _changes.dispose();
    _poll?.cancel();
    _timeout?.cancel();
    _messages?.cancel();
    super.dispose();
  }

  Widget _appIcon(Map<String, dynamic> app) =>
      PhoneAppIcon(encoded: app['icon'] as String?);

  Widget _taskIcon(Map<String, dynamic> task) {
    final package = '${task['component']}'.split('/').first;
    for (final app in _apps) {
      if ('${app['component']}'.split('/').first == package) {
        return _appIcon(app);
      }
    }
    return _appIcon(task);
  }

  void _launch(String component) {
    _action('launch', {
      'component': component,
      if (widget.layoutForApp != null)
        'layout': widget.layoutForApp!(component),
    });
  }

  Map<String, dynamic>? _catalogApp(String component) {
    for (final app in _apps) {
      if (app['component'] == component) return app;
    }
    return null;
  }

  Map<String, dynamic>? _taskApp(Map<String, dynamic> task) {
    final component = '${task['component']}';
    final exact = _catalogApp(component);
    if (exact != null) return exact;
    for (final app in _apps) {
      if ('${app['component']}'.split('/').first ==
          component.split('/').first) {
        return app;
      }
    }
    return null;
  }

  void _toggleTask(Map<String, dynamic> task) => _action(
    task['focused'] == true && task['minimized'] != true ? 'minimize' : 'focus',
    {'taskId': task['id'] as int},
  );

  Future<void> _overview({String? component}) async {
    final selected = await showDialog<int>(
      context: context,
      barrierColor: DesktopStyle.barrier,
      builder: (_) => ListenableBuilder(
        listenable: _changes,
        builder: (_, _) => DesktopTaskOverview(
          tasks: component == null
              ? _tasks
              : _tasks
                    .where(
                      (task) =>
                          '${task['component']}'.split('/').first ==
                          component.split('/').first,
                    )
                    .toList(),
          apps: _apps,
          onAction: (action, id) => _request(
            action,
            values: {
              'taskId': id,
              if (_tasks.any((task) => task['kind'] == 'appWindow'))
                'clientViewport': true,
            },
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (selected != null && _tasks.any((task) => task['id'] == selected)) {
      _action('focus', {'taskId': selected});
    } else {
      widget.onInteraction();
    }
  }

  Future<void> _pinMenu(
    Map<String, dynamic> app,
    List<Map<String, dynamic>> tasks,
    Offset position,
  ) async {
    final store = widget.items!;
    final component = app['component'] as String;
    final pins = store.dockApps;
    final index = pins.indexWhere((pin) => pin['component'] == component);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        DesktopMenuItem(
          value: 'open',
          child: Text(tasks.isEmpty ? '打开应用' : '查看应用窗口'),
        ),
        if (tasks.length == 1) ...[
          DesktopMenuItem(
            value: 'toggle',
            child: Text(tasks.single['minimized'] == true ? '恢复窗口' : '最小化'),
          ),
          const DesktopMenuItem(value: 'close', child: Text('关闭窗口')),
        ],
        if (widget.onAddShortcut != null)
          const DesktopMenuItem(value: 'shortcut', child: Text('添加快捷方式到桌面')),
        const PopupMenuDivider(),
        DesktopMenuItem(
          value: 'previous',
          enabled: index > 0,
          child: const Text('向左移动'),
        ),
        DesktopMenuItem(
          value: 'next',
          enabled: index >= 0 && index < pins.length - 1,
          child: const Text('向右移动'),
        ),
        const DesktopMenuItem(value: 'unpin', child: Text('从 Dock 取消固定')),
      ],
    );
    if (!mounted) return;
    if (action == 'unpin') store.unpinDockApp(component);
    if (action == 'previous') store.moveDockApp(component, -1);
    if (action == 'next') store.moveDockApp(component, 1);
    if (action == 'shortcut') widget.onAddShortcut?.call(app);
    if (action == 'open') _openPin(app, tasks);
    if (tasks.length == 1 && (action == 'toggle' || action == 'close')) {
      _action(
        action == 'close'
            ? 'close'
            : tasks.single['minimized'] == true
            ? 'focus'
            : 'minimize',
        {'taskId': tasks.single['id'] as int},
      );
    }
  }

  void _openPin(
    Map<String, dynamic> app,
    List<Map<String, dynamic>> tasks, {
    bool toggle = false,
  }) {
    final component = app['component'] as String;
    if (tasks.length > 1) {
      _overview(component: component);
    } else if (tasks.isNotEmpty) {
      if (toggle) {
        _toggleTask(tasks.single);
      } else {
        _action('focus', {'taskId': tasks.single['id'] as int});
      }
    } else if (_catalogApp(component) != null) {
      _launch(component);
    } else {
      widget.onProblem('当前手机应用列表中没有「${app['label']}」，可从 Dock 取消固定或刷新应用列表');
    }
  }

  Future<void> _taskMenu(Map<String, dynamic> task, Offset position) async {
    final app = _taskApp(task);
    final store = widget.items;
    final pinned =
        app != null &&
        (store?.isDockPinned(app['component'] as String) ?? false);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const DesktopMenuItem(value: 'minimize', child: Text('最小化')),
        const DesktopMenuItem(value: 'maximize', child: Text('最大化')),
        if (_freeform)
          const DesktopMenuItem(value: 'restore', child: Text('恢复窗口')),
        if (_freeform)
          const DesktopMenuItem(value: 'left', child: Text('靠左排列')),
        if (_freeform)
          const DesktopMenuItem(value: 'right', child: Text('靠右排列')),
        const DesktopMenuItem(value: 'close', child: Text('关闭窗口')),
        if (store != null && app != null) ...[
          const PopupMenuDivider(),
          DesktopMenuItem(
            value: 'pin',
            enabled: pinned || store.dockApps.length < 12,
            child: Text(pinned ? '从 Dock 取消固定' : '固定到 Dock'),
          ),
        ],
      ],
    );
    if (selected != null && mounted) {
      if (selected == 'pin') {
        final component = app!['component'] as String;
        if (pinned) {
          store!.unpinDockApp(component);
        } else {
          store!.pinDockApp(component, '${app['label']}');
        }
        return;
      }
      _action(selected, {'taskId': task['id'] as int});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pins = widget.items?.dockApps ?? [];
    final claimed = <int>{};
    final pinnedItems = <Widget>[];
    for (final pin in pins) {
      final component = pin['component']!;
      final app = _catalogApp(component) ?? pin;
      final tasks = _tasks
          .where(
            (task) =>
                !claimed.contains(task['id']) &&
                '${task['component']}'.split('/').first ==
                    component.split('/').first,
          )
          .toList();
      claimed.addAll(tasks.map((task) => task['id'] as int));
      pinnedItems.add(
        DockItem(
          key: ValueKey('dock-pin-$component'),
          label: '${app['label']}',
          active: tasks.any(
            (task) => task['focused'] == true && task['minimized'] != true,
          ),
          running: tasks.isNotEmpty,
          launchFeedback: true,
          icon: _appIcon(app),
          onTap: () => _openPin(app, tasks, toggle: true),
          onMenu: (position) => _pinMenu(app, tasks, position),
        ),
      );
    }
    final tools = <Widget>[
      DockItem(
        label: '手机应用',
        onTap: _drawer,
        icon: const DockToolIcon(
          icon: Icons.apps_rounded,
          colors: [Color(0xFF698AF7), Color(0xFF5361D9)],
        ),
      ),
      DockItem(
        label: '窗口总览',
        onTap: _overview,
        icon: const DockToolIcon(
          icon: Icons.view_quilt_outlined,
          colors: [Color(0xFFA58CE4), Color(0xFF7862BE)],
        ),
      ),
    ];
    final runningItems = <Widget>[
      for (final task in _tasks.where((task) => !claimed.contains(task['id'])))
        DockItem(
          key: ValueKey(task['id']),
          label: '${task['label']}',
          active: task['focused'] == true && task['minimized'] != true,
          running: true,
          icon: _taskIcon(task),
          onMenu: (position) => _taskMenu(task, position),
          onTap: () => _toggleTask(task),
        ),
    ];
    final hasVisibleWindows = _tasks.any((task) => task['minimized'] != true);
    return DesktopDock(
      autoHide: (widget.items?.dockAutoHide == true) && hasVisibleWindows,
      children: [
        tools.first,
        ...pinnedItems,
        if (runningItems.isNotEmpty) const DockSeparator(),
        ...runningItems,
        const DockSeparator(),
        tools.last,
      ],
    );
  }
}
