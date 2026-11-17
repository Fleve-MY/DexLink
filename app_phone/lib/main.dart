import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/bridge.dart';
import 'src/theme.dart';
import 'src/theme_mode.dart';
import 'src/ui/settings_page.dart';
import 'src/ui/shizuku_onboarding.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.instance.init();
  runApp(const DexLinkApp());
}

class DexLinkApp extends StatelessWidget {
  const DexLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'DexLink',
          debugShowCheckedModeBanner: false,
          theme: AppThemes.light(),
          darkTheme: AppThemes.dark(),
          themeMode: ThemeController.instance.themeMode,
          home: const HomePage(),
        );
      },
    );
  }
}

class _Resolution {
  const _Resolution(this.width, this.height, this.label);
  final int width;
  final int height;
  final String label;
}

const _resolutions = <_Resolution>[
  _Resolution(1280, 720, '720P (1280×720)'),
  _Resolution(1600, 900, '900P (1600×900)'),
  _Resolution(1920, 1080, '1080P (1920×1080) - 推荐'),
  _Resolution(2560, 1440, '2K (2560×1440)'),
  _Resolution(2560, 1600, '16:10 (2560×1600)'),
];

enum DexMode { mirror, desktop }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  PhoneStatus _status = PhoneStatus.empty;
  final List<String> _logs = <String>[];
  StreamSubscription<PhoneEvent>? _subscription;
  int _resolutionIndex = 2;
  int _dpi = 160;
  double _bitrateMbps = 12;
  DexMode _mode = DexMode.mirror;
  bool _awaitingAccessibility = false;
  bool _screenShareProtectionConfirmed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = PhoneBridge.events.listen(_onEvent);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _refresh().then((_) {
      if (!mounted) return;
      if (_awaitingAccessibility && !_status.accessibility) {
        _awaitingAccessibility = false;
        _showRestrictedSettingsHelp();
      }
    });
  }

  void _onEvent(PhoneEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'state':
        setState(() {
          _status = _status.copyWith(
            running: event.running,
            mirrorEngine: event.data['mirrorEngine'] as String?,
            size: event.data['size'] as String?,
            error: (event.data['error'] as String?)?.isEmpty ?? true
                ? null
                : event.data['error'] as String,
            addresses: event.data.containsKey('addresses')
                ? ((event.data['addresses'] as List?) ?? const [])
                      .whereType<Map<dynamic, dynamic>>()
                      .map(NetAddress.fromMap)
                      .toList()
                : null,
          );
        });
      case 'shizuku':
        setState(() => _status = _status.withShizukuEvent(event.data));
      default:
        final level = event.level ?? 'i';
        final message = event.message;
        if (message == null || message.isEmpty) return;
        setState(() {
          _logs.add('${level == 'e' ? '✕' : '·'} $message');
          if (_logs.length > 200) _logs.removeRange(0, _logs.length - 200);
        });
    }
  }

  Future<void> _refresh() async {
    try {
      final status = await PhoneBridge.status();
      final confirmed = await PhoneBridge.screenShareProtectionConfirmed();
      if (!mounted) return;
      setState(() {
        _status = status;
        _screenShareProtectionConfirmed = confirmed;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _logs.add('✕ $error'));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _logs.add('✕ $error'));
    }
    await _refresh();
  }

  Future<void> _startMirror() async {
    await _refresh();
    if (!mounted) return;
    if (_status.addresses.isEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('未检测到局域网连接'),
          content: const Text('请先连接 Wi-Fi，或插上 USB 数据线开启手机系统的「USB 网络共享」。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('仍要启动'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    await _run(PhoneBridge.startMirror);
  }

  bool get _isXiaomi {
    final maker = _status.manufacturer.toLowerCase();
    return maker.contains('xiaomi') ||
        maker.contains('redmi') ||
        maker.contains('poco');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final resolution = _resolutions[_resolutionIndex];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/brand/dexlink.png',
              width: 32,
              height: 32,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 10),
            Text(
              'DexLink',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 19,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (_status.running) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '投屏中',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF10B981),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: isDark ? '切换浅色模式' : '切换深色模式',
            onPressed: () {
              final next = isDark ? AppThemeMode.light : AppThemeMode.dark;
              ThemeController.instance.setMode(next);
            },
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: '刷新状态',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
          IconButton(
            tooltip: '设置与关于',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(
                    status: _status,
                    logs: _logs,
                    onClearLogs: () => setState(_logs.clear),
                    onRefresh: _refresh,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
          children: [
            // 1. 模式选择器
            _buildModeSwitch(theme),
            const SizedBox(height: 14),

            // 2. 核心状态与启动卡片
            _buildHeroCard(theme, resolution),
            const SizedBox(height: 14),

            // 3. 网络与IP信息卡片
            _buildNetworkAddressesCard(theme),
            const SizedBox(height: 14),

            // 4. 自适应内容区（根据当前模式呈现该模式所关心的配置，绝不冗余）
            if (_mode == DexMode.mirror) ...[
              _buildMirrorPermissionsCard(theme),
              if (_isXiaomi) ...[
                const SizedBox(height: 14),
                _buildXiaomiProtectionCard(theme),
              ],
            ] else ...[
              _buildDesktopSettingsCard(theme),
              const SizedBox(height: 14),
              ShizukuOnboarding(
                status: _status,
                onRequestPermission: () => _run(PhoneBridge.requestShizuku),
                onOpenShizuku: () => _run(PhoneBridge.openShizuku),
                onOpenDeveloperOptions: () =>
                    _run(PhoneBridge.openDeveloperOptions),
                onOpenWirelessDebugging: () =>
                    _run(PhoneBridge.openWirelessDebugging),
                onRefresh: _refresh,
              ),
            ],
            const SizedBox(height: 14),
            Card(
              child: ListTile(
                leading: const Icon(Icons.attachment_rounded),
                title: const Text('图片与文件粘贴'),
                subtitle: Text(
                  _status.richInputSelected
                      ? '输入辅助已选择；支持附件的输入框可接收电脑粘贴'
                      : '启用并选择 DexLink 输入辅助',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _run(
                  _status.richInputEnabled
                      ? PhoneBridge.chooseRichInput
                      : PhoneBridge.openRichInputSettings,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSwitch(ThemeData theme) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<DexMode>(
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.comfortable,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        segments: const [
          ButtonSegment(
            value: DexMode.mirror,
            icon: Icon(Icons.smartphone_rounded, size: 18),
            label: Text('屏幕镜像', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          ButtonSegment(
            value: DexMode.desktop,
            icon: Icon(Icons.desktop_windows_rounded, size: 18),
            label: Text('独立桌面', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: _status.running
            ? null
            : (selection) => setState(() => _mode = selection.first),
      ),
    );
  }

  Widget _buildHeroCard(ThemeData theme, _Resolution resolution) {
    final running = _status.running;
    final hasError = _status.error != null && _status.error!.isNotEmpty;
    final isDark = theme.brightness == Brightness.dark;

    final statusColor = running
        ? const Color(0xFF10B981)
        : hasError
        ? const Color(0xFFEF4444)
        : theme.colorScheme.primary;

    final statusTitle = running
        ? (_status.mode == 1 ? '正在屏幕镜像投屏' : '独立桌面运行中')
        : hasError
        ? '发生异常'
        : '准备就绪，等待连接';

    final statusSubtitle = running
        ? (_status.mode == 1
              ? '手机画面正在实时同步到电脑端'
              : '虚拟显示屏规格: ${_status.size ?? resolution.label}')
        : hasError
        ? _status.error!
        : '电脑端启动 DexLink 即可自动发现本机并连接';

    final canStartDesktop = _status.shizukuGranted && !running;

    return Card(
      elevation: isDark ? 0 : 1,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: statusColor.withValues(alpha: 0.4),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusTitle,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        statusSubtitle,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (running)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 0,
                ),
                onPressed: () => _run(PhoneBridge.stop),
                icon: const Icon(Icons.stop_circle_rounded, size: 20),
                label: const Text(
                  '停止投屏',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              )
            else if (_mode == DexMode.mirror)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _startMirror,
                icon: const Icon(Icons.play_circle_filled_rounded, size: 20),
                label: const Text(
                  '开始投屏',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              )
            else
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: canStartDesktop
                    ? () => _run(
                        () => PhoneBridge.start(
                          width: resolution.width,
                          height: resolution.height,
                          dpi: _dpi,
                          bitrate: (_bitrateMbps * 1000000).round(),
                        ),
                      )
                    : null,
                icon: Icon(
                  canStartDesktop
                      ? Icons.play_circle_filled_rounded
                      : Icons.lock_outline_rounded,
                  size: 20,
                ),
                label: Text(
                  canStartDesktop ? '启动独立桌面' : '请先完成下方 Shizuku 授权',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkAddressesCard(ThemeData theme) {
    final addresses =
        _status.addresses.where((a) => a.usb).toList() +
        _status.addresses.where((a) => !a.usb).toList();
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.wifi_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '本机连接地址',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '轻触复制',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (addresses.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '未检测到网络连接（请连接与电脑相同的 Wi-Fi，或插线开启「USB 网络共享」）',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final addr in addresses)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        final text = '${addr.ip}:${_status.port}';
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已复制 IP 端口: $text'),
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF0F1420)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark
                                ? const Color(0xFF1E283D)
                                : const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              addr.usb ? Icons.usb_rounded : Icons.wifi_rounded,
                              size: 15,
                              color: addr.usb
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFF3B82F6),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${addr.ip}:${_status.port}',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.copy_rounded,
                              size: 13,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMirrorPermissionsCard(ThemeData theme) {
    final accessibility = _status.accessibility;
    final allFiles = _status.allFiles;
    final shizukuReady = _status.shizukuAvailable && _status.shizukuGranted;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            _settingRow(
              theme,
              icon: Icons.mouse_rounded,
              title: '电脑键鼠控制',
              subtitle: shizukuReady
                  ? '已开启 Shizuku 增强控制；普通镜像也可配合无障碍服务'
                  : (accessibility
                        ? '已开启无障碍服务，可正常接受电脑鼠标点击与滑动'
                        : '未开启（在电脑端只能看画面，无法操作手机）'),
              ok: accessibility || shizukuReady,
              actionLabel: (accessibility || shizukuReady) ? '已开启' : '去开启',
              onTap: () {
                _awaitingAccessibility = true;
                _run(PhoneBridge.openAccessibility);
              },
            ),
            if (!accessibility && !shizukuReady)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 36, bottom: 8),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _showRestrictedSettingsHelp,
                    child: Text(
                      '系统提示「受限设置 / 权限受限」解决方法',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            const Divider(height: 1),
            _settingRow(
              theme,
              icon: Icons.folder_shared_rounded,
              title: '全盘文件互传',
              subtitle: allFiles
                  ? '已允许访问全部文件，电脑端可随心管理手机存储'
                  : '未授权（授权后电脑端可浏览手机文件并拖拽互传）',
              ok: allFiles,
              actionLabel: allFiles ? '已授权' : '去授权',
              onTap: allFiles
                  ? null
                  : () => _run(PhoneBridge.openAllFilesAccess),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopSettingsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.display_settings_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '独立桌面参数配置',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    '显示分辨率',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      value: _resolutionIndex,
                      onChanged: _status.running
                          ? null
                          : (v) => setState(() => _resolutionIndex = v!),
                      items: [
                        for (var i = 0; i < _resolutions.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              _resolutions[i].label,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    '界面缩放',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _dpi,
                    onChanged: _status.running
                        ? null
                        : (v) => setState(() => _dpi = v!),
                    items: const [
                      DropdownMenuItem(value: 120, child: Text('紧凑 (120 DPI)')),
                      DropdownMenuItem(
                        value: 160,
                        child: Text('标准 (160 DPI) - 推荐'),
                      ),
                      DropdownMenuItem(value: 200, child: Text('大号 (200 DPI)')),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    '传输码率',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _bitrateMbps,
                    min: 4,
                    max: 30,
                    divisions: 13,
                    onChanged: _status.running
                        ? null
                        : (v) => setState(() => _bitrateMbps = v),
                  ),
                ),
                SizedBox(
                  width: 68,
                  child: Text(
                    '${_bitrateMbps.round()} Mbps',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildXiaomiProtectionCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.blur_off_rounded,
                  size: 20,
                  color: Color(0xFFF59E0B),
                ),
                const SizedBox(width: 8),
                Text(
                  '小米投屏防模糊设置',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  _screenShareProtectionConfirmed ? '已确认关闭' : '未确认',
                  style: TextStyle(
                    fontSize: 12,
                    color: _screenShareProtectionConfirmed
                        ? const Color(0xFF10B981)
                        : const Color(0xFFF59E0B),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'HyperOS / MIUI 默认开启「屏幕共享防护」，会导致微信等应用在投屏画面中变模糊。如已关闭该功能，请点击确认。',
              style: TextStyle(
                fontSize: 12.5,
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => _run(PhoneBridge.openScreenShareProtection),
                  child: const Text('去系统设置'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => _run(
                    () => PhoneBridge.confirmScreenShareProtection(
                      !_screenShareProtectionConfirmed,
                    ),
                  ),
                  child: Text(
                    _screenShareProtectionConfirmed ? '重新标记未确认' : '我已关闭，确认',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingRow(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool ok,
    required String actionLabel,
    VoidCallback? onTap,
  }) {
    final okColor = const Color(0xFF10B981);
    final disabledColor = theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (ok ? okColor : disabledColor).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: ok ? okColor : disabledColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (onTap != null)
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              onPressed: onTap,
              child: Text(actionLabel, style: const TextStyle(fontSize: 12.5)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: okColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                actionLabel,
                style: TextStyle(
                  color: okColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showRestrictedSettingsHelp() {
    final manufacturer = _status.manufacturer.toLowerCase();
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
                  '如何开启受限的无障碍控制权限',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(
                  'Android 13+ 出于安全策略，默认限制侧载应用的无障碍权限。\n'
                  '操作步骤：\n'
                  '1. 轻触下方「打开应用信息」\n'
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
                        _run(PhoneBridge.openAppSettings);
                      },
                      child: const Text('打开应用信息'),
                    ),
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _awaitingAccessibility = true;
                        _run(PhoneBridge.openAccessibility);
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
