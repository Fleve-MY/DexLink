import 'package:flutter/material.dart';

import '../desktop_items.dart';
import 'phone_app_icon.dart';
import 'desktop_style.dart';

/// Launches phone apps; local organization does not modify installed packages.
class DesktopAppDrawer extends StatefulWidget {
  const DesktopAppDrawer({
    super.key,
    required this.apps,
    this.items,
    this.onAddShortcut,
    this.onRefresh,
    required this.onProblem,
  });
  final List<Map<String, dynamic>> apps;
  final DesktopItems? items;
  final ValueChanged<Map<String, dynamic>>? onAddShortcut;
  final VoidCallback? onRefresh;
  final ValueChanged<String> onProblem;
  @override
  State<DesktopAppDrawer> createState() => _DesktopAppDrawerState();
}

class _DesktopAppDrawerState extends State<DesktopAppDrawer> {
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> menu(Map<String, dynamic> app, Offset position) async {
    final store = widget.items;
    final component = app['component'] as String;
    final pinned = store?.isDockPinned(component) ?? false;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const DesktopMenuItem(value: 'open', child: Text('打开应用')),
        if (widget.onAddShortcut != null)
          const DesktopMenuItem(value: 'shortcut', child: Text('添加快捷方式到桌面')),
        if (store != null)
          DesktopMenuItem(
            value: 'pin',
            enabled: pinned || store.dockApps.length < 12,
            child: Text(pinned ? '从 Dock 取消固定' : '固定到 Dock'),
          ),
      ],
    );
    if (!mounted) return;
    if (action == 'open') Navigator.pop(context, component);
    if (action == 'shortcut') widget.onAddShortcut?.call(app);
    if (action == 'pin') {
      if (pinned) {
        store!.unpinDockApp(component);
      } else if (!store!.pinDockApp(component, '${app['label']}')) {
        widget.onProblem('Dock 最多固定 12 个应用');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final apps =
        widget.apps
            .where(
              (app) => '${app['label']} ${app['component']}'
                  .toLowerCase()
                  .contains(query),
            )
            .toList()
          ..sort(
            (a, b) => '${a['label']}'.toLowerCase().compareTo(
              '${b['label']}'.toLowerCase(),
            ),
          );
    return DesktopPanel(
      title: '手机应用',
      closeLabel: '关闭应用抽屉',
      actions: [
        if (widget.onRefresh != null)
          IconButton(
            tooltip: '刷新应用列表',
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: search,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '搜索应用',
                filled: true,
                fillColor: const Color(0xFFF0F1F3),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除应用搜索',
                        onPressed: () => setState(search.clear),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (apps.isNotEmpty) {
                  Navigator.pop(context, apps.first['component'] as String);
                }
              },
            ),
            const SizedBox(height: 12),
            Text(
              query.isEmpty ? '${apps.length} 个应用' : '找到 ${apps.length} 个应用',
              style: const TextStyle(fontSize: 12, color: Color(0xFF717780)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: apps.isEmpty
                  ? const Center(child: Text('没有匹配的应用'))
                  : GridView.extent(
                      maxCrossAxisExtent: 120,
                      childAspectRatio: 1,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [
                        for (final app in apps)
                          Tooltip(
                            message: '${app['label']}',
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                key: ValueKey('drawer-app-${app['component']}'),
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => Navigator.pop(
                                  context,
                                  app['component'] as String,
                                ),
                                onSecondaryTapUp: (event) =>
                                    menu(app, event.globalPosition),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 32,
                                        height: 32,
                                        child: PhoneAppIcon(
                                          encoded: app['icon'] as String?,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '${app['label']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
