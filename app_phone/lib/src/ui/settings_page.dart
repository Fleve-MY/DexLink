import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge.dart';
import '../theme_mode.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.status,
    required this.logs,
    required this.onClearLogs,
    required this.onRefresh,
  });

  final PhoneStatus status;
  final List<String> logs;
  final VoidCallback onClearLogs;
  final Future<void> Function() onRefresh;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currentTheme = ThemeController.instance.currentMode;

    return Scaffold(
      appBar: AppBar(title: const Text('设置与偏好')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // 1. 外观主题
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.palette_outlined,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '外观与主题',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final mode in AppThemeMode.values) ...[
                        Expanded(
                          child: ChoiceChip(
                            label: Center(
                              child: Text(
                                mode.label,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: currentTheme == mode
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                            selected: currentTheme == mode,
                            onSelected: (_) {
                              setState(
                                () => ThemeController.instance.setMode(mode),
                              );
                            },
                          ),
                        ),
                        if (mode != AppThemeMode.values.last)
                          const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // 2. 运行日志
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '运行日志 (${widget.logs.length})',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '清空日志',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.logs.isEmpty
                            ? null
                            : widget.onClearLogs,
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                      ),
                      IconButton(
                        tooltip: '复制全部日志',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.logs.isEmpty
                            ? null
                            : () {
                                Clipboard.setData(
                                  ClipboardData(text: widget.logs.join('\n')),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('已复制日志到剪贴板'),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    height: 180,
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF070A0F)
                          : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF1E2638)
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                    child: widget.logs.isEmpty
                        ? Center(
                            child: Text(
                              '暂无运行日志',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          )
                        : ListView.builder(
                            reverse: true,
                            itemCount: widget.logs.length,
                            itemBuilder: (context, index) {
                              final line =
                                  widget.logs[widget.logs.length - 1 - index];
                              final isErr = line.startsWith('✕');
                              return Text(
                                line,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  height: 1.45,
                                  color: isErr
                                      ? const Color(0xFFEF4444)
                                      : (isDark
                                            ? const Color(0xFF94A3B8)
                                            : const Color(0xFF334155)),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // 3. 常见问题：受限制设置帮助
          Card(
            child: ListTile(
              leading: Icon(
                Icons.help_outline_rounded,
                color: theme.colorScheme.primary,
              ),
              title: const Text(
                '系统提示「受限设置」解决方法',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Android 13+ 对侧载应用的无障碍权限指引',
                style: TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () => _showRestrictedSettingsDialog(context),
            ),
          ),
          const SizedBox(height: 14),

          // 4. 关于 DexLink
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'assets/brand/dexlink.png',
                        width: 24,
                        height: 24,
                        excludeFromSemantics: true,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '关于 DexLink',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      const Text(
                        'v0.1.0',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'DexLink 是专为 Android 设备量身打造的高性能投屏与虚拟桌面协同套件。支持原生超低延迟镜像、独立虚拟桌面与全盘文件传输。',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showRestrictedSettingsDialog(BuildContext context) {
    final manufacturer = widget.status.manufacturer.toLowerCase();
    final romHint = switch (manufacturer) {
      'xiaomi' || 'redmi' || 'poco' => '应用信息 → 右上角设置图标（或右上角三个点）→ 允许受限制的设置',
      'oppo' || 'realme' || 'oneplus' => '应用信息 → 右上角「⋮」→ 允许应用获取权限',
      'vivo' || 'iqoo' => '应用信息 → 右上角「⋮」→ 允许受限制的设置',
      _ => '应用信息 → 右上角「⋮」→ 允许受限制的设置',
    };

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '如何开启受限制的权限',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(
                  'Android 13+ 出于安全策略，默认限制侧载应用的无障碍权限。\n'
                  '操作步骤：\n'
                  '1. 点击下方「打开应用信息」\n'
                  '2. $romHint\n'
                  '3. 返回后再次点击「去开启」即可正常启用。',
                  style: const TextStyle(height: 1.7, fontSize: 13),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        PhoneBridge.openAppSettings();
                      },
                      child: const Text('打开应用信息'),
                    ),
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        PhoneBridge.openAccessibility();
                      },
                      child: const Text('去无障碍设置'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
