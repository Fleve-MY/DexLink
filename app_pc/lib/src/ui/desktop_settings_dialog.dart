import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../desktop_items.dart';
import 'desktop_style.dart';
import 'desktop_widgets.dart';

class WallpaperPreset {
  const WallpaperPreset({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.colors,
  });

  final String id;
  final String title;
  final String subtitle;
  final List<Color> colors;
}

const wallpapers = [
  WallpaperPreset(
    id: 'macos_wave',
    title: '流光波浪',
    subtitle: 'macOS 经典流线',
    colors: [Color(0xFFEAEAF9), Color(0xFF798DE1), Color(0xFF4363BA)],
  ),
  WallpaperPreset(
    id: 'sonoma',
    title: '索诺玛暖霞',
    subtitle: '晨曦暖橙与淡紫',
    colors: [Color(0xFFFDE8D7), Color(0xFFE88A72), Color(0xFF674B8C)],
  ),
  WallpaperPreset(
    id: 'monterey',
    title: '蒙特雷极光',
    subtitle: '深邃紫罗兰与暗晶',
    colors: [Color(0xFF1B1832), Color(0xFF563678), Color(0xFF8B4FA5)],
  ),
  WallpaperPreset(
    id: 'midnight',
    title: '黑曜午夜',
    subtitle: '纯粹暗黑极简',
    colors: [Color(0xFF0F1117), Color(0xFF1E2433), Color(0xFF131722)],
  ),
  WallpaperPreset(
    id: 'sequoia',
    title: '红杉原野',
    subtitle: '清澈蓝空与葱郁',
    colors: [Color(0xFFD8EDF2), Color(0xFF59929B), Color(0xFF26535F)],
  ),
];

Future<void> showDesktopSettings(BuildContext context, DesktopItems store) {
  return showDialog<void>(
    context: context,
    barrierColor: DesktopStyle.barrier,
    builder: (context) => DesktopPanel(
      title: '桌面与外观偏好设置',
      closeLabel: '关闭设置',
      width: 660,
      height: 640,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) => _DesktopSettingsContent(store: store),
      ),
    ),
  );
}

class _DesktopSettingsContent extends StatelessWidget {
  const _DesktopSettingsContent({required this.store});

  final DesktopItems store;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section: 壁纸选择
          _buildSectionHeader(context, Icons.wallpaper_rounded, '桌面壁纸'),
          const SizedBox(height: 12),
          _WallpaperPicker(store: store),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),

          // Section: 程序坞 (Dock)
          _buildSectionHeader(context, Icons.dock_rounded, '程序坞 (Dock)'),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动隐藏和显示程序坞'),
            subtitle: const Text('当全屏或窗口遮挡时自动向下滑出隐藏，鼠标移到底部边缘时滑出'),
            value: store.dockAutoHide,
            onChanged: store.setDockAutoHide,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用鼠标指针悬停图标放大'),
            subtitle: const Text('macOS 经典弹性放大缩放视觉反馈'),
            value: store.dockMagnification,
            onChanged: store.setDockMagnification,
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),

          // Section: 桌面小组件
          _buildSectionHeader(context, Icons.widgets_outlined, '桌面小组件'),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('在桌面上显示小组件'),
            subtitle: const Text('在桌面右上角显示时钟、日历、待办与便签等毛玻璃小组件'),
            value: store.widgetsVisible,
            onChanged: store.setWidgetsVisible,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('锁定小组件位置'),
            subtitle: const Text('锁定后无法任意拖动和缩放组件，防止误触'),
            value: store.widgetsLocked,
            onChanged: store.setWidgetsLocked,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                showDesktopWidgets(context, store);
              },
              icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
              label: const Text('添加与管理小组件...'),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),

          // Section: 窗口与自适应优化
          _buildSectionHeader(context, Icons.aspect_ratio_rounded, '应用窗口自适应'),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('无黑边自适应拉伸与视口填充'),
            subtitle: const Text('最大化或缩放窗口时优先消除两边黑边，使手机应用完整利用整个屏幕视口'),
            value: store.appWindowAdaptive,
            onChanged: store.setAppWindowAdaptive,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('新打开应用的默认布局'),
            subtitle: const Text('随窗口自适应 / 平板宽屏 / 平板标准 / 手机比例'),
            trailing: DropdownButton<String>(
              value: store.defaultAppLayout,
              underline: const SizedBox(),
              borderRadius: BorderRadius.circular(10),
              onChanged: (val) {
                if (val != null) store.setDefaultAppLayout(val);
              },
              items: const [
                DropdownMenuItem(value: 'responsive', child: Text('随窗口自适应 (无黑边)')),
                DropdownMenuItem(value: 'tabletWide', child: Text('宽屏平板 (大视野)')),
                DropdownMenuItem(value: 'tablet', child: Text('平板标准 (推荐)')),
                DropdownMenuItem(value: 'phone', child: Text('手机比例 (兼容)')),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF007AFF)),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: DesktopStyle.ink,
          ),
        ),
      ],
    );
  }
}


class _WallpaperPicker extends StatefulWidget {
  const _WallpaperPicker({required this.store});
  final DesktopItems store;

  @override
  State<_WallpaperPicker> createState() => _WallpaperPickerState();
}

class _WallpaperPickerState extends State<_WallpaperPicker> {
  final ScrollController _scroll = ScrollController();
  bool _canScrollLeft = false;
  bool _canScrollRight = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateScrollButtons();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_updateScrollButtons);
    _scroll.dispose();
    super.dispose();
  }

  void _updateScrollButtons() {
    if (!_scroll.hasClients) return;
    final canLeft = _scroll.offset > 4;
    final canRight = _scroll.offset < _scroll.position.maxScrollExtent - 4;
    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  void _scrollBy(double delta) {
    if (!_scroll.hasClients) return;
    final target = (_scroll.offset + delta).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 104,
      child: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent && _scroll.hasClients) {
                  final delta = event.scrollDelta.dy != 0
                      ? event.scrollDelta.dy
                      : event.scrollDelta.dx;
                  _scroll.jumpTo(
                    (_scroll.offset + delta)
                        .clamp(0.0, _scroll.position.maxScrollExtent),
                  );
                }
              },
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                  },
                ),
                child: ListView.separated(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: wallpapers.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, index) {
                    final wp = wallpapers[index];
                    final isSelected = widget.store.wallpaper == wp.id;
                    return GestureDetector(
                      onTap: () => widget.store.setWallpaper(wp.id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 130,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFF007AFF)
                                : const Color(0x33818A98),
                            width: isSelected ? 2.5 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: const Color(0xFF007AFF)
                                        .withValues(alpha: 0.25),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ]
                              : null,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: wp.colors,
                                    ),
                                  ),
                                  child: isSelected
                                      ? Center(
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: const BoxDecoration(
                                              color: Color(0xFF007AFF),
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(
                                              Icons.check_rounded,
                                              color: Colors.white,
                                              size: 14,
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              wp.title,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isSelected
                                    ? const Color(0xFF007AFF)
                                    : theme.textTheme.bodyMedium?.color,
                              ),
                            ),
                            const SizedBox(height: 2),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          if (_canScrollLeft)
            Positioned(
              left: 2,
              top: 24,
              child: Material(
                color: Colors.white.withValues(alpha: 0.9),
                shape: const CircleBorder(),
                elevation: 3,
                shadowColor: const Color(0x33000000),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _scrollBy(-160),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.chevron_left_rounded,
                      size: 20,
                      color: Color(0xFF2C323D),
                    ),
                  ),
                ),
              ),
            ),
          if (_canScrollRight)
            Positioned(
              right: 2,
              top: 24,
              child: Material(
                color: Colors.white.withValues(alpha: 0.9),
                shape: const CircleBorder(),
                elevation: 3,
                shadowColor: const Color(0x33000000),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _scrollBy(160),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: Color(0xFF2C323D),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
