import 'package:flutter/material.dart';

import '../bridge.dart';

class ShizukuOnboarding extends StatelessWidget {
  const ShizukuOnboarding({
    super.key,
    required this.status,
    required this.onRequestPermission,
    required this.onOpenShizuku,
    required this.onOpenDeveloperOptions,
    required this.onOpenWirelessDebugging,
    required this.onRefresh,
  });

  final PhoneStatus status;
  final VoidCallback onRequestPermission;
  final VoidCallback onOpenShizuku;
  final VoidCallback onOpenDeveloperOptions;
  final VoidCallback onOpenWirelessDebugging;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stage = status.shizukuStage;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  stage == 3 ? Icons.check_circle : Icons.security,
                  size: 18,
                  color: stage == 3
                      ? const Color(0xFF4ADE80)
                      : const Color(0xFFF59E0B),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '增强控制权限',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(onPressed: onRefresh, child: const Text('刷新')),
              ],
            ),
            _step(
              theme,
              index: 1,
              title: '安装并启动 ${status.managerName}',
              done: status.shizukuAvailable,
              action: TextButton(
                onPressed: onOpenShizuku,
                child: Text(status.shizukuInstalled ? '打开' : '安装'),
              ),
            ),
            _step(
              theme,
              index: 2,
              title: '授权 DexLink',
              done: status.shizukuGranted,
              action: TextButton(
                onPressed: status.shizukuAvailable && !status.shizukuGranted
                    ? onRequestPermission
                    : null,
                child: Text(status.shizukuGranted ? '已授权' : '授权'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(
    ThemeData theme, {
    required int index,
    required String title,
    required bool done,
    required Widget action,
  }) {
    return Row(
      children: [
        Icon(
          done ? Icons.check : Icons.circle_outlined,
          size: 15,
          color: done ? const Color(0xFF4ADE80) : const Color(0xFF64748B),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('$index. $title', style: const TextStyle(fontSize: 13)),
        ),
        action,
      ],
    );
  }
}
