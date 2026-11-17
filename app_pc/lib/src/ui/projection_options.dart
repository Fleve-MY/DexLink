import 'package:dex_link/dex_link.dart';
import 'package:flutter/material.dart';

import '../projection_settings.dart';
import 'desktop_dropdown.dart';

class ProjectionOptions extends StatelessWidget {
  const ProjectionOptions({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final ProjectionSettings value;
  final ValueChanged<ProjectionSettings> onChanged;

  void _change({
    int? size,
    int? bitrate,
    bool? screenOff,
    bool? audio,
    bool? hevc,
  }) {
    onChanged(
      ProjectionSettings(
        capture: CaptureOptions(
          maxSize: size ?? value.capture.maxSize,
          bitrate: bitrate ?? value.capture.bitrate,
          features: hevc == null
              ? value.capture.features
              : hevc
              ? value.capture.features | kCapturePreferHevc
              : value.capture.features & ~kCapturePreferHevc,
        ),
        screenOff: screenOff ?? value.screenOff,
        audio: audio ?? value.audio,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capture = value.capture;
    Widget choice(
      String label,
      int selected,
      List<int> values,
      String Function(int) text,
      ValueChanged<int> change,
    ) {
      final options = {...values, selected}.toList()..sort();
      return DesktopDropdown<int>(
        label: label,
        value: selected,
        options: [
          for (final option in options)
            DropdownOption(value: option, label: text(option)),
        ],
        onChanged: change,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('投屏设置', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final preset in [
              ('流畅', 1600, 8000000),
              ('均衡', 1920, 12000000),
              ('清晰', 2560, 24000000),
            ])
              ActionChip(
                label: Text(preset.$1),
                onPressed: () => _change(size: preset.$2, bitrate: preset.$3),
              ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('以稳定 60 帧为目标，静止画面按需更新'),
        const SizedBox(height: 12),
        choice(
          '分辨率 · 长边',
          capture.maxSize,
          [1280, 1600, 1920, 2560, 3840],
          (n) => '$n 像素',
          (n) => _change(size: n),
        ),
        const SizedBox(height: 12),
        choice(
          '视频码率',
          capture.bitrate,
          [4000000, 8000000, 12000000, 16000000, 24000000, 32000000, 50000000],
          (n) => '${n ~/ 1000000} Mbps',
          (n) => _change(bitrate: n),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('优先使用 H.265 编码', style: TextStyle(fontSize: 13)),
          subtitle: const Text('可改善相同带宽下的清晰度；需两端支持硬件编解码，不支持时使用 H.264'),
          value: capture.features & kCapturePreferHevc != 0,
          onChanged: (next) => _change(hevc: next),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('在电脑播放手机声音', style: TextStyle(fontSize: 13)),
          subtitle: const Text('需要 Shizuku 增强模式与 Android 12+；部分应用限制音频采集'),
          value: value.audio,
          onChanged: (next) => _change(audio: next),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('连接后自动关闭手机面板', style: TextStyle(fontSize: 13)),
          subtitle: const Text('仅在手机支持息屏投屏时生效'),
          value: value.screenOff,
          onChanged: (next) => _change(screenOff: next),
        ),
        const Text(
          '连接前设置，按手机比例缩放且不放大原图。动态画面最高 60 帧；实际流畅度取决于应用、设备和网络。',
          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
        ),
      ],
    );
  }
}
