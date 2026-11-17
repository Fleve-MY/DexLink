import 'package:flutter/material.dart';

import '../usb_installer.dart';

class UsbSetupDialog extends StatefulWidget {
  const UsbSetupDialog({super.key, required this.installer});
  final UsbInstaller installer;

  @override
  State<UsbSetupDialog> createState() => _UsbSetupDialogState();
}

class _UsbSetupDialogState extends State<UsbSetupDialog> {
  List<UsbPhone> _phones = const [];
  List<BundledApk> _packages = const [];
  String? _serial;
  UsbPhoneInfo? _info;
  Set<String> _selected = {};
  bool _busy = false;
  bool _installing = false;
  String? _error;
  String? _result;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh({String? serial}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final packages = await widget.installer.packages();
      final phones = await widget.installer.devices();
      final wanted = serial ?? _serial;
      // Never silently switch to another phone after a disconnect.
      final current = wanted == null
          ? (phones.length == 1 ? phones.single : null)
          : phones.where((phone) => phone.serial == wanted).firstOrNull;
      final info = current?.ready == true
          ? await widget.installer.inspect(current!)
          : null;
      if (!mounted) return;
      setState(() {
        _packages = packages;
        _phones = phones;
        _serial = current?.serial;
        _info = info;
        _selected = info == null
            ? {}
            : widget.installer
                  .recommended(info, packages)
                  .map((apk) => apk.id)
                  .toSet();
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final info = _info;
    if (_busy || info == null || _selected.isEmpty) return;
    setState(() {
      _busy = true;
      _installing = true;
      _error = null;
      _result = null;
      _progress = '正在检查手机和安装包…';
    });
    try {
      await widget.installer.install(
        info,
        {..._selected},
        onProgress: (message) {
          if (mounted) setState(() => _progress = message);
        },
      );
      if (mounted) {
        setState(() => _result = '安装完成。请在手机上打开 DexLink；增强控制还需启动管理器并授权。');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        final installError = _error;
        setState(() {
          _busy = false;
          _installing = false;
          _progress = '';
        });
        await _refresh(serial: info.phone.serial);
        if (mounted && installError != null) {
          setState(() => _error = installError);
        }
      }
    }
  }

  void _toggle(BundledApk apk, bool value) {
    setState(() {
      if (value) {
        _selected.add(apk.id);
        if (apk.id == 'nightzuku' && !_info!.installed.containsKey('shizuku')) {
          _selected.add('shizuku');
        }
      } else {
        _selected.remove(apk.id);
        if (apk.id == 'shizuku' && !_info!.installed.containsKey('shizuku')) {
          _selected.remove('nightzuku');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final current = _phones
        .where((phone) => phone.serial == _serial)
        .firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_installing,
      child: AlertDialog(
        title: const Text('USB 安装'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('连接数据线，开启 USB 调试，并在手机上允许此电脑。'),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey(_serial),
                  initialValue: _serial,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'USB 手机'),
                  hint: Text(_phones.isEmpty ? '未检测到手机' : '请选择手机'),
                  items: [
                    for (final phone in _phones)
                      DropdownMenuItem(
                        value: phone.serial,
                        child: Text(
                          phone.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          _result = null;
                          _refresh(serial: value);
                        },
                ),
                if (current != null && !current.ready) ...[
                  const SizedBox(height: 12),
                  Text(
                    current.state == 'unauthorized'
                        ? '等待手机允许 USB 调试。确认后点击刷新。'
                        : '手机离线，请重新插线后刷新。',
                  ),
                ],
                if (!_busy && _phones.isEmpty && _error == null) ...[
                  const SizedBox(height: 12),
                  const Text('未检测到 USB 调试设备。请检查数据线、USB 调试和手机驱动。'),
                ],
                if (info != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Android ${info.release}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (info.sdk >= 37)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Android 17 方案：Shizuku + Nightzuku'),
                    ),
                  const SizedBox(height: 8),
                  for (final apk in _packages)
                    if (apk.id != 'nightzuku' || info.sdk >= 37) ...[
                      Builder(
                        builder: (context) {
                          final installed = info.installed[apk.id];
                          final newer =
                              installed != null && installed > apk.versionCode;
                          final supported = info.sdk >= apk.minSdk;
                          return CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(apk.label),
                            subtitle: Text(
                              !supported
                                  ? 'Android 版本不支持'
                                  : newer
                                  ? '已安装较新版本，将保留'
                                  : installed == null
                                  ? '未安装 · 内置 ${apk.version}'
                                  : '已安装 · 内置 ${apk.version}',
                            ),
                            value: _selected.contains(apk.id),
                            onChanged: _busy || newer || !supported
                                ? null
                                : (value) => _toggle(apk, value ?? false),
                          );
                        },
                      ),
                    ],
                ],
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_installing ? _progress : '正在检测…'),
                ],
                if (_result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _result!,
                      style: TextStyle(color: scheme.primary),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _refresh(),
            child: const Text('刷新'),
          ),
          TextButton(
            onPressed: _installing ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: _busy || info == null || _selected.isEmpty
                ? null
                : _install,
            icon: const Icon(Icons.install_mobile_rounded, size: 18),
            label: Text(_installing ? '安装中…' : '安装选中应用'),
          ),
        ],
      ),
    );
  }
}
