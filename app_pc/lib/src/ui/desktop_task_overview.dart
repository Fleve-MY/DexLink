import 'package:flutter/material.dart';

import 'phone_app_icon.dart';
import 'desktop_style.dart';

/// Uses live task state without starting extra decoders for window thumbnails.
class DesktopTaskOverview extends StatelessWidget {
  const DesktopTaskOverview({
    super.key,
    required this.tasks,
    required this.apps,
    required this.onAction,
  });
  final List<Map<String, dynamic>> tasks, apps;
  final void Function(String action, int id) onAction;

  @override
  Widget build(BuildContext context) => DesktopPanel(
    closeLabel: '关闭窗口总览',
    width: tasks.isEmpty ? 480 : 760,
    height: tasks.isEmpty
        ? 250
        : tasks.length <= 2
        ? 270
        : 450,
    child: tasks.isEmpty
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xFFEBEEF8),
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Icon(
                      Icons.window_rounded,
                      size: 30,
                      color: DesktopStyle.accent,
                    ),
                  ),
                ),
                SizedBox(height: 18),
                Text(
                  '暂无打开的应用窗口',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: DesktopStyle.ink,
                  ),
                ),
              ],
            ),
          )
        : GridView.extent(
            padding: const EdgeInsets.all(20),
            maxCrossAxisExtent: 380,
            mainAxisExtent: 158,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [for (final task in tasks) _card(context, task)],
          ),
  );

  Widget _card(BuildContext context, Map<String, dynamic> task) {
    final id = task['id'] as int;
    final component = '${task['component']}';
    final matches = apps.where(
      (app) =>
          app['component'] == component ||
          '${app['component']}'.split('/').first == component.split('/').first,
    );
    final icon = matches.isEmpty ? task['icon'] : matches.first['icon'];
    final active = task['focused'] == true && task['minimized'] != true;
    return Material(
      color: active ? const Color(0xFFE8F0FC) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: active ? const Color(0xFF5685C0) : const Color(0xFFE0E5EC),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('overview-task-$id'),
        onTap: () => Navigator.pop(context, id),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: PhoneAppIcon(encoded: icon as String?),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${task['label'] ?? '应用窗口'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭${task['label'] ?? '窗口'}',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onAction('close', id),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                task['minimized'] == true
                    ? '已最小化'
                    : active
                    ? '当前窗口'
                    : '正在运行',
                style: const TextStyle(fontSize: 12, color: Color(0xFF62718A)),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (task['minimized'] != true)
                    IconButton(
                      tooltip: '最小化${task['label'] ?? '窗口'}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onAction('minimize', id),
                      icon: const Icon(Icons.minimize, size: 18),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, id),
                    child: Text(task['minimized'] == true ? '恢复窗口' : '切换窗口'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
