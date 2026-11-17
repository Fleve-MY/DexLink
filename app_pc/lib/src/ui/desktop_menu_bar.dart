import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'desktop_clock.dart';
import 'desktop_style.dart';

/// Desktop status belongs above the workspace, separate from app launch icons.
class DesktopMenuBar extends StatelessWidget {
  const DesktopMenuBar({
    super.key,
    required this.activeApp,
    required this.connected,
    required this.audioEnabled,
    required this.audioMuted,
    required this.onAudio,
    required this.onAction,
    required this.onDrag,
    required this.onMaximize,
    required this.onMinimize,
    required this.onClose,
    required this.settings,
  });
  final String activeApp;
  final bool connected, audioEnabled, audioMuted;
  final VoidCallback onAudio, onDrag, onMaximize, onMinimize, onClose;
  final ValueChanged<String> onAction;
  final Widget settings;

  Widget _menu(String title, List<PopupMenuEntry<String>> entries) =>
      PopupMenuButton<String>(
        tooltip: '$title菜单',
        position: PopupMenuPosition.under,
        offset: const Offset(0, 6),
        onSelected: onAction,
        itemBuilder: (_) => entries,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title == 'DexLink') ...[
                  Image.asset(
                    'assets/brand/dexlink.png',
                    width: 18,
                    height: 18,
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: title == 'DexLink'
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: const Color(0xFF292B35),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) {
      final compact = constraints.maxWidth < 720;
      final contrast = MediaQuery.highContrastOf(context);
      return Theme(
        data: DesktopStyle.theme(context),
        child: Material(
          color: Colors.transparent,
          child: SizedBox(
            height: 34,
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: contrast ? 0 : 18,
                  sigmaY: contrast ? 0 : 18,
                ),
                child: DecoratedBox(
                  key: const ValueKey('desktop-menu-bar'),
                  decoration: BoxDecoration(
                    color: contrast
                        ? const Color(0xFFF8F7FB)
                        : const Color(0xA8F8F7FB),
                    border: const Border(
                      bottom: BorderSide(color: Color(0x36FFFFFF), width: .5),
                    ),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      _menu('DexLink', [
                        const DesktopMenuItem(
                          value: 'home',
                          child: Text('显示桌面'),
                        ),
                        const DesktopMenuItem(
                          value: 'widgets',
                          child: Text('桌面小组件'),
                        ),
                        const DesktopMenuItem(
                          value: 'settings',
                          child: Text('桌面设置...'),
                        ),
                        const DesktopMenuItem(
                          value: 'overview',
                          child: Text('窗口总览'),
                        ),
                        const PopupMenuDivider(),
                        const DesktopMenuItem(
                          value: 'files',
                          child: Text('文件传输'),
                        ),
                        const DesktopMenuItem(
                          value: 'paste',
                          child: Text('粘贴剪贴板   Ctrl+V'),
                        ),
                        const DesktopMenuItem(
                          value: 'decoder',
                          child: Text('视频解码设置'),
                        ),
                        const DesktopMenuItem(
                          value: 'diagnostics',
                          child: Text('诊断信息   F12'),
                        ),
                        const PopupMenuDivider(),
                        const DesktopMenuItem(
                          value: 'exit',
                          child: Text('退出桌面模式'),
                        ),
                      ]),
                      if (!compact) ...[
                        _menu('桌面', const [
                          DesktopMenuItem(value: 'home', child: Text('显示桌面')),
                          DesktopMenuItem(
                            value: 'widgets',
                            child: Text('桌面小组件'),
                          ),
                          DesktopMenuItem(
                            value: 'settings',
                            child: Text('桌面设置...'),
                          ),
                        ]),
                        _menu('窗口', const [
                          DesktopMenuItem(
                            value: 'overview',
                            child: Text('窗口总览'),
                          ),
                          DesktopMenuItem(
                            value: 'maximize',
                            child: Text('最大化 / 还原桌面窗口'),
                          ),
                        ]),
                      ],
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => onDrag(),
                          onDoubleTap: onMaximize,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: Text(
                                compact || activeApp == '桌面' ? '' : activeApp,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF71717D),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (!compact)
                        Tooltip(
                          message: connected ? '手机已连接' : '手机未连接',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(
                              Icons.smartphone_rounded,
                              size: 14,
                              color: connected
                                  ? const Color(0xFF525460)
                                  : const Color(0xFF8B95A5),
                            ),
                          ),
                        ),
                      if (!compact)
                        IconButton(
                          tooltip: !audioEnabled
                              ? '连接设置中开启手机声音'
                              : audioMuted
                              ? '恢复电脑播放手机声音'
                              : '静音电脑上的手机声音',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 32,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: audioEnabled ? onAudio : null,
                          icon: Icon(
                            audioMuted || !audioEnabled
                                ? Icons.volume_off_outlined
                                : Icons.volume_up_outlined,
                            size: 17,
                            color: const Color(0xFF525460),
                          ),
                        ),
                      SizedBox(width: 30, child: settings),
                      DesktopClock(
                        menuBar: true,
                        darkText: true,
                        compact: compact,
                      ),
                      if (!compact) ...[
                        const SizedBox(
                          height: 16,
                          child: VerticalDivider(width: 16),
                        ),
                        IconButton(
                          tooltip: '最小化',
                          onPressed: onMinimize,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          icon: const Icon(Icons.remove_rounded, size: 16),
                        ),
                        IconButton(
                          tooltip: '最大化 / 还原桌面窗口',
                          onPressed: onMaximize,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          icon: const Icon(Icons.crop_square_rounded, size: 14),
                        ),
                      ],
                      Tooltip(
                        message: '退出桌面模式',
                        child: TextButton(
                          key: const ValueKey('exit-desktop'),
                          onPressed: onClose,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(30, 30),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            foregroundColor: DesktopStyle.ink,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.logout_rounded, size: 15),
                              if (!compact) ...[
                                const SizedBox(width: 5),
                                const Text(
                                  '退出桌面',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'Roboto',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
