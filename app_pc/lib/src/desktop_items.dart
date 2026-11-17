import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class DesktopItem {
  const DesktopItem({
    required this.id,
    required this.label,
    this.component,
    this.parent,
  });
  final String id, label;
  final String? component, parent;
  bool get isFolder => component == null;
  DesktopItem copy({String? label, String? parent, bool root = false}) =>
      DesktopItem(
        id: id,
        label: label ?? this.label,
        component: component,
        parent: root ? null : parent ?? this.parent,
      );
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'component': component,
    'parent': parent,
  };
}

/// PC desktop organization only. Removing an entry never uninstalls an app or
/// deletes anything in the phone filesystem. All mutation paths share one store.
class DesktopItems extends ChangeNotifier {
  DesktopItems({File? file, this.onError, this.writeLayout})
    : file =
          file ??
          File(
            '${Platform.environment['LOCALAPPDATA'] ?? Directory.current.path}/DexLink/desktop.json',
          ) {
    try {
      if (!this.file.existsSync()) return;
      final data = jsonDecode(this.file.readAsStringSync()) as Map;
      if (data['version'] != 1) throw const FormatException('桌面数据版本不兼容');
      final ids = <String>{};
      for (final value in data['items'] as List) {
        final row = value as Map;
        final id = row['id'] as String;
        if (!ids.add(id)) throw const FormatException('桌面条目重复');
        _items.add(
          DesktopItem(
            id: id,
            label: row['label'] as String,
            component: row['component'] as String?,
            parent: row['parent'] as String?,
          ),
        );
      }
      _initialized = true;
      _lastItemState = jsonEncode(_items.map((item) => item.toJson()).toList());
      if (data['appLayouts'] case final Map layouts) {
        for (final entry in layouts.entries) {
          if (entry.key is String &&
              const [
                'tablet',
                'tabletWide',
                'responsive',
                'phone',
              ].contains(entry.value)) {
            appLayouts[entry.key as String] = entry.value as String;
          }
        }
      }
      if (data['widgets'] case final List widgets) {
        for (final row in widgets.whereType<Map>()) {
          if (const [
            'clock',
            'calendar',
            'note',
            'todo',
          ].contains(row['kind'])) {
            desktopWidgets.add(Map<String, dynamic>.from(row));
          }
        }
      }
      widgetsVisible = data['widgetsVisible'] != false;
      widgetsLocked = data['widgetsLocked'] == true;
      if (data['wallpaper'] is String) wallpaper = data['wallpaper'] as String;
      if (data['dockAutoHide'] is bool) dockAutoHide = data['dockAutoHide'] as bool;
      if (data['dockMagnification'] is bool) dockMagnification = data['dockMagnification'] as bool;
      if (data['dockPosition'] is String) dockPosition = data['dockPosition'] as String;
      if (data['defaultAppLayout'] is String) defaultAppLayout = data['defaultAppLayout'] as String;
      if (data['appWindowAdaptive'] is bool) appWindowAdaptive = data['appWindowAdaptive'] as bool;
      if (data['dockApps'] case final List apps) {
        for (final app in apps.whereType<Map>()) {
          if (app['component'] is String && app['label'] is String) {
            final component = app['component'] as String;
            if (component.isNotEmpty &&
                !_dockApps.any((entry) => entry['component'] == component) &&
                _dockApps.length < 12) {
              _dockApps.add({
                'component': component,
                'label': app['label'] as String,
              });
            }
          }
        }
      }
    } catch (error) {
      onError?.call('读取桌面布局失败：$error');
    }
  }
  final File file;
  final ValueChanged<String>? onError;

  /// Allows previews/tests to keep persistence outside Flutter's fake clock.
  final Future<void> Function(String)? writeLayout;
  final List<DesktopItem> _items = [];
  bool _initialized = false;
  final List<Map<String, String>> _dockApps = [];
  List<Map<String, String>> get dockApps => List.unmodifiable(
    _dockApps.map((app) => Map<String, String>.unmodifiable(app)),
  );
  bool isDockPinned(String component) =>
      _dockApps.any((app) => app['component'] == component);

  bool pinDockApp(String component, String label) {
    if (component.isEmpty) return false;
    if (isDockPinned(component)) return true;
    if (_dockApps.length >= 12) return false;
    _dockApps.add({'component': component, 'label': label});
    _changed();
    return true;
  }

  void unpinDockApp(String component) {
    _dockApps.removeWhere((app) => app['component'] == component);
    _changed();
  }

  void moveDockApp(String component, int delta) {
    final index = _dockApps.indexWhere((app) => app['component'] == component);
    if (index < 0) return;
    final target = (index + delta).clamp(0, _dockApps.length - 1);
    if (index == target) return;
    _dockApps.insert(target, _dockApps.removeAt(index));
    _changed();
  }

  String _lastItemState = '[]';
  final List<String> _undoItems = [], _redoItems = [];
  bool get canUndoDesktop => _undoItems.isNotEmpty;
  bool get canRedoDesktop => _redoItems.isNotEmpty;

  void undoDesktop() => _restoreItems(_undoItems, _redoItems);
  void redoDesktop() => _restoreItems(_redoItems, _undoItems);
  void _restoreItems(List<String> source, List<String> target) {
    if (source.isEmpty) return;
    target.add(_lastItemState);
    final rows = jsonDecode(source.removeLast()) as List;
    _items
      ..clear()
      ..addAll(
        rows.map((value) {
          final row = value as Map;
          return DesktopItem(
            id: row['id'] as String,
            label: row['label'] as String,
            component: row['component'] as String?,
            parent: row['parent'] as String?,
          );
        }),
      );
    _initialized = true;
    _changed(recordHistory: false);
  }

  final List<Map<String, dynamic>> desktopWidgets = [];
  bool widgetsVisible = true, widgetsLocked = false;
  final List<Map<String, dynamic>> _removedWidgets = [];
  bool get canRestoreWidget =>
      _removedWidgets.isNotEmpty && desktopWidgets.length < 8;
  void setWidgetsVisible(bool value) {
    widgetsVisible = value;
    _changed();
  }

  void setWidgetsLocked(bool value) {
    widgetsLocked = value;
    _changed();
  }

  final Map<String, String> appLayouts = {};
  String layoutFor(String component) => appLayouts[component] ?? defaultAppLayout;
  void setAppLayout(String component, String layout) {
    if (!const [
      'tablet',
      'tabletWide',
      'responsive',
      'phone',
    ].contains(layout)) {
      return;
    }
    appLayouts[component] = layout;
    _changed();
  }

  String wallpaper = 'macos_wave';
  void setWallpaper(String value) {
    if (wallpaper == value) return;
    wallpaper = value;
    _changed();
  }

  bool dockAutoHide = false;
  void setDockAutoHide(bool value) {
    if (dockAutoHide == value) return;
    dockAutoHide = value;
    _changed();
  }

  bool dockMagnification = true;
  void setDockMagnification(bool value) {
    if (dockMagnification == value) return;
    dockMagnification = value;
    _changed();
  }

  String dockPosition = 'bottom';
  void setDockPosition(String value) {
    if (dockPosition == value) return;
    dockPosition = value;
    _changed();
  }

  String defaultAppLayout = 'tablet';
  void setDefaultAppLayout(String value) {
    if (defaultAppLayout == value) return;
    defaultAppLayout = value;
    _changed();
  }

  bool appWindowAdaptive = true;
  void setAppWindowAdaptive(bool value) {
    if (appWindowAdaptive == value) return;
    appWindowAdaptive = value;
    _changed();
  }

  Timer? _widgetSave;
  void setWidgetText(String id, String text) {
    for (final item in desktopWidgets) {
      if (item['id'] == id) item['text'] = text;
    }
    _widgetSave?.cancel();
    _widgetSave = Timer(const Duration(milliseconds: 450), () {
      _widgetSave = null;
      _changed();
    });
  }

  @override
  void dispose() {
    if (_widgetSave != null) {
      _widgetSave!.cancel();
      _widgetSave = null;
      _changed(notify: false);
    }
    super.dispose();
  }

  final List<String> _clipboard = [];
  bool _cut = false;
  bool get canPaste => _clipboard.any((id) => byId(id) != null);

  void copySelection(Iterable<String> ids, {bool cut = false}) {
    _clipboard
      ..clear()
      ..addAll(ids.where((id) => byId(id) != null));
    _cut = cut;
  }

  bool paste(String? parent) {
    final ids = _clipboard.where((id) => byId(id) != null).toList();
    if (ids.isEmpty || ids.any((id) => !canMove(id, parent))) return false;
    if (_cut) {
      final moved = moveMany(ids, parent);
      if (moved) _clipboard.clear();
      return moved;
    }
    // Snapshot before copying so a new folder cannot copy its own descendants.
    final snapshot = List<DesktopItem>.of(_items);
    void clone(DesktopItem item, String? target) {
      final copy = DesktopItem(
        id: _id(),
        label: item.label,
        component: item.component,
        parent: target,
      );
      _items.add(copy);
      for (final child in snapshot.where((entry) => entry.parent == item.id)) {
        clone(child, copy.id);
      }
    }

    for (final id in ids) {
      final item = byId(id)!;
      // A selected descendant is already included in its selected parent.
      var ancestor = byId(item.parent);
      var covered = false;
      while (ancestor != null) {
        if (ids.contains(ancestor.id)) {
          covered = true;
          break;
        }
        ancestor = byId(ancestor.parent);
      }
      if (!covered) clone(item, parent);
    }
    _changed();
    return true;
  }

  void addWidget(String kind) {
    if (!const ['clock', 'calendar', 'note', 'todo'].contains(kind) ||
        desktopWidgets.length >= 8) {
      return;
    }
    final offset = desktopWidgets.length * .05;
    desktopWidgets.add({
      'id': _id(),
      'kind': kind,
      'x': (.75 - offset).clamp(0, 1),
      'y': (.04 + offset).clamp(0, 1),
      'large': false,
      'text': '',
      if (kind == 'todo') 'tasks': <Map<String, dynamic>>[],
    });
    widgetsVisible = true;
    _changed();
  }

  void updateWidget(String id, Map<String, dynamic> values) {
    for (final item in desktopWidgets) {
      if (item['id'] == id) {
        item.addAll(values);
        _changed();
        return;
      }
    }
  }

  void removeWidget(String id) {
    final index = desktopWidgets.indexWhere((item) => item['id'] == id);
    if (index < 0) return;
    _removedWidgets.add(
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(desktopWidgets[index])) as Map,
      ),
    );
    if (_removedWidgets.length > 20) _removedWidgets.removeAt(0);
    desktopWidgets.removeWhere((item) => item['id'] == id);
    _changed();
  }

  void restoreWidget() {
    if (!canRestoreWidget) return;
    desktopWidgets.add(_removedWidgets.removeLast());
    widgetsVisible = true;
    _changed();
  }

  void duplicateWidget(String id) {
    if (desktopWidgets.length >= 8) return;
    final index = desktopWidgets.indexWhere((item) => item['id'] == id);
    if (index < 0) return;
    final copy = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(desktopWidgets[index])) as Map,
    );
    copy['id'] = _id();
    copy['hidden'] = false;
    if (copy['left'] is num) copy['left'] = (copy['left'] as num) + 24;
    if (copy['top'] is num) copy['top'] = (copy['top'] as num) + 24;
    desktopWidgets.add(copy);
    widgetsVisible = true;
    _changed();
  }

  void raiseWidget(String id) {
    final index = desktopWidgets.indexWhere((item) => item['id'] == id);
    if (index < 0 || index == desktopWidgets.length - 1) return;
    desktopWidgets.add(desktopWidgets.removeAt(index));
    _changed();
  }

  void addWidgetTask(String id, String label) {
    final value = label.trim();
    if (value.isEmpty) return;
    for (final item in desktopWidgets) {
      if (item['id'] != id || item['kind'] != 'todo') continue;
      final tasks = (item['tasks'] as List? ?? [])
          .whereType<Map>()
          .map((task) => Map<String, dynamic>.from(task))
          .toList();
      if (tasks.length >= 100) return;
      tasks.add({
        'id': _id(),
        'label': value.substring(0, value.length.clamp(0, 200)),
        'done': false,
      });
      updateWidget(id, {'tasks': tasks});
      return;
    }
  }

  void updateWidgetTask(
    String id,
    String taskId, {
    bool? done,
    bool remove = false,
  }) {
    for (final item in desktopWidgets) {
      if (item['id'] != id || item['kind'] != 'todo') continue;
      final tasks = (item['tasks'] as List? ?? [])
          .whereType<Map>()
          .map((task) => Map<String, dynamic>.from(task))
          .toList();
      if (remove) {
        tasks.removeWhere((task) => task['id'] == taskId);
      } else {
        for (final task in tasks) {
          if (task['id'] == taskId) task['done'] = done ?? task['done'];
        }
      }
      updateWidget(id, {'tasks': tasks});
      return;
    }
  }

  int _sequence = 0;
  Future<void> _writes = Future.value();
  Future<void> get saved => _writes;
  List<DesktopItem> get items => List.unmodifiable(_items);
  List<DesktopItem> children(String? parent) =>
      _items.where((item) => item.parent == parent).toList();
  DesktopItem? byId(String? id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  String _id() => '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  void seed(List<Map<String, dynamic>> apps) {
    if (_initialized || apps.isEmpty) return;
    _initialized = true;
    final preferred = apps
        .where(
          (app) => RegExp(
            r'浏览器|文件管理|相册|设置|便签|计算器|browser|chrome|files|gallery|notes|settings',
            caseSensitive: false,
          ).hasMatch('${app['label']} ${app['component']}'),
        )
        .take(8)
        .toList();
    for (final app in preferred.isEmpty ? apps.take(6) : preferred) {
      _items.add(
        DesktopItem(
          id: _id(),
          label: '${app['label']}',
          component: app['component'] as String,
        ),
      );
    }
    _changed();
  }

  DesktopItem addApp(String component, String label, {String? parent}) {
    for (final item in _items) {
      if (item.component == component && item.parent == parent) return item;
    }
    final item = DesktopItem(
      id: _id(),
      label: label,
      component: component,
      parent: parent,
    );
    _items.add(item);
    _changed();
    return item;
  }

  DesktopItem createFolder({String? parent}) {
    var label = '新建文件夹', number = 2;
    final names = children(parent).map((item) => item.label).toSet();
    while (names.contains(label)) {
      label = '新建文件夹 ($number)';
      number++;
    }
    final item = DesktopItem(id: _id(), label: label, parent: parent);
    _items.add(item);
    _changed();
    return item;
  }

  void rename(String id, String label) {
    final text = label.trim();
    if (text.isEmpty) return;
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0 || _items[index].label == text) return;
    _items[index] = _items[index].copy(label: text);
    _changed();
  }

  bool move(String id, String? parent, {String? before}) {
    return moveMany([id], parent, before: before);
  }

  bool canMove(String id, String? parent) {
    final item = byId(id);
    if (item == null || id == parent) return false;
    var ancestor = byId(parent);
    if (parent != null && (ancestor == null || !ancestor.isFolder)) {
      return false;
    }
    final visited = <String>{};
    while (ancestor != null) {
      if (ancestor.id == id || !visited.add(ancestor.id)) return false;
      ancestor = byId(ancestor.parent);
    }
    return true;
  }

  bool moveMany(List<String> ids, String? parent, {String? before}) {
    final unique = ids.toSet();
    if (unique.isEmpty ||
        unique.contains(before) ||
        unique.any((id) => !canMove(id, parent))) {
      return false;
    }
    final moved = _items
        .where((item) => unique.contains(item.id))
        .map((item) => item.copy(parent: parent, root: parent == null))
        .toList();
    _items.removeWhere((item) => unique.contains(item.id));
    final index = before == null
        ? -1
        : _items.indexWhere((entry) => entry.id == before);
    if (index < 0) {
      _items.addAll(moved);
    } else {
      _items.insertAll(index, moved);
    }
    _changed();
    return true;
  }

  void remove(String id) {
    removeMany([id]);
  }

  void removeMany(Iterable<String> ids) {
    for (final id in ids.toSet()) {
      _removeItem(id);
    }
    _changed();
  }

  void _removeItem(String id) {
    final item = byId(id);
    if (item == null) return;
    // Dissolving a folder keeps all of its shortcuts in the parent folder.
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].parent == id) {
        _items[i] = _items[i].copy(
          parent: item.parent,
          root: item.parent == null,
        );
      }
    }
    _items.remove(item);
  }

  void sortByName(String? parent) {
    final sorted = children(parent)
      ..sort((a, b) {
        if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    var index = 0;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].parent == parent) _items[i] = sorted[index++];
    }
    _changed();
  }

  void _changed({bool notify = true, bool recordHistory = true}) {
    final current = jsonEncode(_items.map((item) => item.toJson()).toList());
    if (current != _lastItemState) {
      if (recordHistory) {
        _undoItems.add(_lastItemState);
        if (_undoItems.length > 30) _undoItems.removeAt(0);
        _redoItems.clear();
      }
      _lastItemState = current;
    }
    final text = jsonEncode({
      'version': 1,
      'items': _items.map((item) => item.toJson()).toList(),
      'widgets': desktopWidgets,
      'widgetsVisible': widgetsVisible,
      'widgetsLocked': widgetsLocked,
      'dockApps': _dockApps,
      'appLayouts': appLayouts,
      'wallpaper': wallpaper,
      'dockAutoHide': dockAutoHide,
      'dockMagnification': dockMagnification,
      'dockPosition': dockPosition,
      'defaultAppLayout': defaultAppLayout,
      'appWindowAdaptive': appWindowAdaptive,
    });
    // Serialize saves so a slower earlier write cannot replace the latest layout.
    _writes = _writes
        .then((_) async {
          if (writeLayout != null) {
            await writeLayout!(text);
            return;
          }
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(text, flush: true);
          await temporary.rename(file.path);
        })
        .catchError((Object error) {
          onError?.call('保存桌面布局失败：$error');
        });
    if (notify) notifyListeners();
  }
}
