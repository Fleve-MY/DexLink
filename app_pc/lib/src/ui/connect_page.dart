import 'dart:async';

import 'package:dex_link/dex_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../device_scanner.dart';
import '../last_device.dart';
import '../decoder_settings.dart';
import '../projection_settings.dart';
import '../session_log.dart';
import '../theme_settings.dart';
import '../usb_installer.dart';
import 'projection_options.dart';
import 'desktop_dropdown.dart';
import 'desktop_page.dart';
import 'usb_setup_dialog.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController(text: '27190');

  List<FoundDevice> _devices = const [];
  bool _scanning = false;
  DecoderMode _decoderMode = DecoderSettings.read();
  ProjectionSettings _projection = ProjectionSettings.read();
  Timer? _timer;

  String? _lastHost;
  int _lastPort = kDefaultTcpPort;

  @override
  void initState() {
    super.initState();
    _scheduleScanning();
    _loadLastDevice();
    _scan();
  }

  Future<void> _loadLastDevice() async {
    final value = await LastDeviceStore.read();
    if (value == null || !mounted) return;
    final separator = value.lastIndexOf(':');
    if (separator <= 0) return;
    final port = int.tryParse(value.substring(separator + 1));
    if (port == null) return;
    final host = value.substring(0, separator);
    setState(() {
      _lastHost = host;
      _lastPort = port;
      if (_host.text.isEmpty) {
        _host.text = host;
        _port.text = '$port';
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _scheduleScanning() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_scanning) _scan();
    });
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final devices = await DeviceScanner.scan(extraHost: _lastHost);
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _scanning = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _devices = const [];
      });
    }
  }

  Future<void> _connect(String host, int port) async {
    _timer?.cancel();
    await LastDeviceStore.write(host, port);
    if (mounted) {
      setState(() {
        _lastHost = host;
        _lastPort = port;
      });
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopPage(
          host: host,
          port: port,
          decoderMode: _decoderMode,
          captureOptions: _projection.capture,
          screenOff: _projection.screenOff,
          audio: _projection.audio,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _decoderMode = DecoderSettings.read());
    _scheduleScanning();
    _scan();
  }

  void _connectManually() {
    final port = int.tryParse(_port.text.trim());
    final host = _host.text.trim();
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请输入合法的 IP 地址与端口号'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    _connect(host, port);
  }

  static bool _isUsb(String host) {
    return host.startsWith('192.168.42.') ||
        host.startsWith('192.168.43.') ||
        host.startsWith('172.20.10.') ||
        host.startsWith('10.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xFF0F141F) : Colors.white,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            color: isDark ? const Color(0xFF1E2638) : const Color(0xFFE2E8F0),
            height: 1,
          ),
        ),
        title: Row(
          children: [
            Image.asset(
              'assets/brand/dexlink.png',
              width: 34,
              height: 34,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 10),
            Text(
              'DexLink',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '控制台',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          // 刷新扫描按钮
          TextButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 18),
            label: Text(_scanning ? '搜索中…' : '刷新设备'),
          ),
          const SizedBox(width: 4),

          // 快捷键指南
          IconButton(
            tooltip: '快捷键速查',
            onPressed: () => _showShortcutsDialog(context, theme, isDark),
            icon: const Icon(Icons.keyboard_outlined, size: 20),
          ),

          // 运行日志
          IconButton(
            tooltip: '运行会话日志',
            onPressed: () => _showLogsDialog(context, theme, isDark),
            icon: const Icon(Icons.terminal_rounded, size: 20),
          ),

          // 一键切换主题
          IconButton(
            tooltip: isDark ? '切换浅色模式' : '切换深色模式',
            onPressed: () {
              final next = isDark ? PcThemeMode.light : PcThemeMode.dark;
              PcThemeSettings.instance.setMode(next);
            },
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 20,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 760;

          if (isWide) {
            // 桌面端黄金双栏一体化主控台
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左栏：设备发现与连接中心
                Expanded(
                  flex: 58,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: _buildConnectSection(theme, isDark),
                  ),
                ),
                Container(
                  width: 1,
                  color: isDark
                      ? const Color(0xFF1E2638)
                      : const Color(0xFFE2E8F0),
                ),
                // 右栏：投屏与显示参数即时配置
                Expanded(
                  flex: 42,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: _buildSettingsSection(theme, isDark),
                  ),
                ),
              ],
            );
          } else {
            // 紧凑窗口自适应单列纵向流
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _buildConnectSection(theme, isDark),
                  const SizedBox(height: 20),
                  _buildSettingsSection(theme, isDark),
                ],
              ),
            );
          }
        },
      ),
    );
  }

  // =========================================================================
  // 1. 设备连接模块 (Connect Section)
  // =========================================================================
  Widget _buildConnectSection(ThemeData theme, bool isDark) {
    final showLast =
        _lastHost != null &&
        !_devices.any((d) => d.host == _lastHost && d.port == _lastPort);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 发现设备卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.wifi_tethering_rounded,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '已发现的手机设备',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _devices.isNotEmpty
                            ? const Color(0xFF10B981).withValues(alpha: 0.12)
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.1,
                              ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _devices.isNotEmpty ? '${_devices.length} 台在线' : '搜索中',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _devices.isNotEmpty
                              ? const Color(0xFF10B981)
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_devices.isNotEmpty)
                  for (var i = 0; i < _devices.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    _deviceTile(_devices[i], theme, isDark),
                  ]
                else
                  _emptyDeviceGuide(theme, isDark),
              ],
            ),
          ),
        ),

        if (showLast) ...[
          const SizedBox(height: 16),
          _lastDeviceCard(theme, isDark),
        ],

        const SizedBox(height: 16),

        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            leading: Icon(Icons.usb_rounded, color: theme.colorScheme.primary),
            title: const Text('USB 安装手机应用'),
            subtitle: const Text('内置 DexLink、Shizuku 和 Nightzuku'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => UsbSetupDialog(installer: UsbInstaller()),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 手动直连手机卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.link_rounded,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '手动直连手机',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '若跨网段未自动发现，可直接输入手机显示的 IP 地址与端口：',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 13.5,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'IP 地址',
                          hintText: '如 192.168.8.59',
                          prefixIcon: Icon(Icons.router_outlined, size: 18),
                        ),
                        onSubmitted: (_) => _connectManually(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: _port,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 13.5,
                        ),
                        decoration: const InputDecoration(
                          labelText: '端口',
                          hintText: '27190',
                        ),
                        onSubmitted: (_) => _connectManually(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 15,
                        ),
                      ),
                      onPressed: _connectManually,
                      child: const Text(
                        '连接',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyDeviceGuide(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0D121B) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF1E283D) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.phonelink_ring_rounded,
            size: 36,
            color: theme.colorScheme.primary.withValues(alpha: 0.75),
          ),
          const SizedBox(height: 10),
          Text(
            '尚未探测到局域网手机',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '请在手机端打开 DexLink 并点击「开始投屏」即可在此处自动显示。\n支持连接同一 Wi-Fi 或插数据线开启「USB 网络共享」。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceTile(FoundDevice device, ThemeData theme, bool isDark) {
    final usb = _isUsb(device.host);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _connect(device.host, device.port),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF131926) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? const Color(0xFF222F47) : const Color(0xFFE2E8F0),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: (usb ? const Color(0xFF10B981) : const Color(0xFF3B82F6))
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                usb ? Icons.usb_rounded : Icons.smartphone_rounded,
                color: usb ? const Color(0xFF10B981) : const Color(0xFF3B82F6),
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        device.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color:
                              (usb
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFF3B82F6))
                                  .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          usb ? 'USB 高速' : 'Wi-Fi 无线',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: usb
                                ? const Color(0xFF10B981)
                                : const Color(0xFF3B82F6),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${device.host}:${device.port}',
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'Consolas',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              onPressed: () => _connect(device.host, device.port),
              icon: const Icon(Icons.login_rounded, size: 16),
              label: const Text(
                '连接',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lastDeviceCard(ThemeData theme, bool isDark) {
    final host = _lastHost!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.history_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '最近连接: $host:$_lastPort',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
              ),
              onPressed: () => _connect(host, _lastPort),
              child: const Text('快速重连', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // 2. 投屏显示参数模块 (Settings & Display Section)
  // =========================================================================
  Widget _buildSettingsSection(ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 视频解码模式卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.video_settings_rounded,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '视频解码加速',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DesktopDropdown<DecoderMode>(
                  label: '解码加速模式',
                  value: _decoderMode,
                  options: const [
                    DropdownOption(
                      value: DecoderMode.auto,
                      label: '自动优选（优先硬解）',
                      description: '优先尝试 GPU 硬件加速，异常时自动平滑回退',
                    ),
                    DropdownOption(
                      value: DecoderMode.hardware,
                      label: '硬件加速解码',
                      description: '强制启用系统 GPU 硬解，系统负载极低',
                    ),
                    DropdownOption(
                      value: DecoderMode.software,
                      label: '软件解码',
                      description: '使用 FFmpeg 纯 CPU 软件解码，兼容性极高',
                    ),
                  ],
                  onChanged: (mode) async {
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _decoderMode = mode);
                    try {
                      await DecoderSettings.write(mode);
                    } catch (_) {
                      if (!mounted) return;
                      messenger.showSnackBar(
                        const SnackBar(content: Text('设置已生效，但写入配置文件失败')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 投屏画质与高级选项
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ProjectionOptions(
              value: _projection,
              onChanged: (value) async {
                final messenger = ScaffoldMessenger.of(context);
                setState(() => _projection = value);
                try {
                  await value.save();
                } catch (_) {
                  if (!mounted) return;
                  messenger.showSnackBar(
                    const SnackBar(content: Text('设置已生效，但写入磁盘失败')),
                  );
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // 3. 弹窗：快捷键速查
  // =========================================================================
  void _showShortcutsDialog(
    BuildContext context,
    ThemeData theme,
    bool isDark,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.keyboard_outlined, size: 22),
            SizedBox(width: 10),
            Text('投屏快捷键速查'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _shortcutItem('F11', '切换全屏 / 窗口化显示', theme, isDark),
              const Divider(height: 14),
              _shortcutItem('鼠标右键', '触发手机「返回键」(Back 键)', theme, isDark),
              const Divider(height: 14),
              _shortcutItem('鼠标中键', '触发手机「桌面主屏键」(Home 键)', theme, isDark),
              const Divider(height: 14),
              _shortcutItem('Ctrl + V', '自动将电脑剪贴板（文本/图片）粘贴到手机', theme, isDark),
              const Divider(height: 14),
              _shortcutItem('文件拖拽', '直接将电脑文件拖拽到窗口传给手机', theme, isDark),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('了解'),
          ),
        ],
      ),
    );
  }

  Widget _shortcutItem(
    String keyName,
    String desc,
    ThemeData theme,
    bool isDark,
  ) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E283D) : const Color(0xFFE2E8F0),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            keyName,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(desc, style: const TextStyle(fontSize: 12.5))),
      ],
    );
  }

  // =========================================================================
  // 4. 弹窗：会话运行日志
  // =========================================================================
  void _showLogsDialog(BuildContext context, ThemeData theme, bool isDark) {
    final logText = SessionLog.read();
    final lines = logText
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();

    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.terminal_rounded, size: 22),
                  const SizedBox(width: 10),
                  Text('运行会话日志 (${lines.length})'),
                  const Spacer(),
                  IconButton(
                    tooltip: '清空日志',
                    onPressed: () {
                      SessionLog.clear();
                      setDialogState(() => lines.clear());
                    },
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: '复制全部日志',
                    onPressed: lines.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                              ClipboardData(text: lines.join('\n')),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制日志到剪贴板')),
                            );
                          },
                    icon: const Icon(Icons.copy_rounded, size: 20),
                  ),
                ],
              ),
              content: SizedBox(
                width: 600,
                height: 380,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF070A0F)
                        : const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: lines.isEmpty
                      ? const Center(
                          child: Text(
                            '暂无运行日志',
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 13,
                            ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          itemCount: lines.length,
                          itemBuilder: (context, index) {
                            final line = lines[lines.length - 1 - index];
                            final isErr =
                                line.contains('异常') ||
                                line.contains('失败') ||
                                line.contains('Error');
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 1.5,
                              ),
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: isErr
                                      ? const Color(0xFFF87171)
                                      : const Color(0xFF94A3B8),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
