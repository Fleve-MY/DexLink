import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class UsbSetupException implements Exception {
  const UsbSetupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AdbReply {
  const AdbReply(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

typedef AdbCommand = Future<AdbReply> Function(
  List<String> arguments,
  Duration timeout,
);

class BundledApk {
  const BundledApk({
    required this.id,
    required this.label,
    required this.package,
    required this.version,
    required this.versionCode,
    required this.minSdk,
    required this.file,
    required this.sha256,
  });
  final String id, label, package, version, file, sha256;
  final int versionCode, minSdk;
}

class UsbPhone {
  const UsbPhone(this.serial, this.state, this.model);
  final String serial, state, model;
  bool get ready => state == 'device';
  String get label => model.isEmpty ? serial : '$model · $serial';
}

class UsbPhoneInfo {
  const UsbPhoneInfo(this.phone, this.sdk, this.release, this.installed);
  final UsbPhone phone;
  final int sdk;
  final String release;
  final Map<String, int> installed;
}

/// Owns only USB setup; video discovery and transport stay independent.
class UsbInstaller {
  UsbInstaller({Directory? directory, this.command})
    : directory =
          directory ??
          Directory(p.join(p.dirname(Platform.resolvedExecutable), 'support'));

  final Directory directory;
  final AdbCommand? command;
  List<BundledApk>? _apks;
  bool _adbVerified = false;
  bool _installing = false;

  Future<List<BundledApk>> packages() async {
    if (_apks != null) return _apks!;
    try {
      final document = jsonDecode(
        await File(p.join(directory.path, 'manifest.json')).readAsString(),
      ) as Map<String, dynamic>;
      final packages = (document['packages'] as List).map((item) {
        final data = item as Map<String, dynamic>;
        return BundledApk(
          id: data['id'] as String,
          label: data['label'] as String,
          package: data['package'] as String,
          version: data['version'] as String,
          versionCode: data['versionCode'] as int,
          minSdk: data['minSdk'] as int,
          file: data['file'] as String,
          sha256: data['sha256'] as String,
        );
      }).toList();
      if (packages.map((apk) => apk.id).toSet().length != 3 ||
          !packages.map((apk) => apk.id).toSet().containsAll([
            'dexlink',
            'shizuku',
            'nightzuku',
          ])) {
        throw const FormatException('Missing setup packages');
      }
      return _apks = List.unmodifiable(packages);
    } catch (_) {
      throw const UsbSetupException('内置安装包缺失，请重新解压完整的 DexLink 电脑版。');
    }
  }

  Future<void> _verify(String relative, String expected) async {
    final path = p.normalize(p.join(directory.path, relative));
    if (!p.isWithin(p.absolute(directory.path), p.absolute(path))) {
      throw const UsbSetupException('内置安装包路径无效。');
    }
    final file = File(path);
    if (!await file.exists() ||
        (await sha256.bind(file.openRead()).first).toString() != expected) {
      throw const UsbSetupException('内置文件缺失或损坏，请重新解压完整的 DexLink 电脑版。');
    }
  }

  Future<AdbReply> _run(
    List<String> args, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final command = this.command;
    if (command != null) return command(args, timeout);
    try {
      if (!_adbVerified) {
        final document = jsonDecode(
          await File(p.join(directory.path, 'manifest.json')).readAsString(),
        ) as Map<String, dynamic>;
        for (final entry in (document['adb'] as Map<String, dynamic>).entries) {
          await _verify(entry.key, entry.value as String);
        }
        _adbVerified = true;
      }
      final process = await Process.start(
        p.join(directory.path, 'adb', 'adb.exe'),
        args,
        workingDirectory: p.join(directory.path, 'adb'),
        runInShell: false,
      );
      final output = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final error = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      int code;
      try {
        code = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        process.kill();
        throw const UsbSetupException('USB 操作超时，请检查手机提示和连接后重试。');
      }
      return AdbReply(code, '${await output}\n${await error}'.trim());
    } on UsbSetupException {
      rethrow;
    } catch (_) {
      throw const UsbSetupException('USB 工具无法启动，请重新解压完整的 DexLink 电脑版。');
    }
  }

  static List<UsbPhone> parseDevices(String output) {
    final phones = <UsbPhone>[];
    for (final line in const LineSplitter().convert(output)) {
      final match = RegExp(r'^(\S+)\s+(device|unauthorized|offline)\b(.*)$')
          .firstMatch(line);
      if (match == null) continue;
      final serial = match[1]!;
      // Network ADB and emulators must not be mistaken for the plugged-in phone.
      if (serial.startsWith('emulator-') ||
          serial.contains(':') ||
          serial.contains('_adb-tls-') ||
          serial.contains('._tcp')) {
        continue;
      }
      final model = RegExp(r'\bmodel:(\S+)').firstMatch(match[3]!);
      phones.add(
        UsbPhone(serial, match[2]!, model?[1]?.replaceAll('_', ' ') ?? ''),
      );
    }
    return phones;
  }

  Future<List<UsbPhone>> devices() async {
    final reply = await _run(['devices', '-l']);
    if (reply.exitCode != 0) throw UsbSetupException(_failure(reply.output));
    return parseDevices(reply.output);
  }

  Future<AdbReply> _shell(String serial, List<String> args) async {
    final reply = await _run(['-s', serial, 'shell', ...args]);
    if (reply.exitCode != 0 ||
        RegExp(r'(^|\n)(error:|Error:|Exception|Security exception|java\.)')
            .hasMatch(reply.output)) {
      throw UsbSetupException(_failure(reply.output));
    }
    return reply;
  }

  Future<int?> _installed(String serial, BundledApk apk) async {
    final reply = await _shell(serial, [
      'pm',
      'list',
      'packages',
      '--show-versioncode',
      '--user',
      'current',
      apk.package,
    ]);
    final expression = RegExp(
      '^package:${RegExp.escape(apk.package)} versionCode:(\\d+)\$',
      multiLine: true,
    );
    final match = expression.firstMatch(reply.output.replaceAll('\r', ''));
    if (match != null) return int.parse(match[1]!);
    if (reply.output.trim().isNotEmpty) {
      throw const UsbSetupException('无法确认手机应用版本，请刷新设备后重试。');
    }
    return null;
  }

  Future<UsbPhoneInfo> inspect(UsbPhone phone) async {
    if (!phone.ready) throw const UsbSetupException('请先在手机上允许 USB 调试。');
    final apks = await packages();
    final sdk = int.tryParse(
      (await _shell(phone.serial, [
        'getprop',
        'ro.build.version.sdk',
      ])).output.trim(),
    );
    if (sdk == null) throw const UsbSetupException('无法读取 Android 版本，请重新连接手机。');
    final release = (await _shell(phone.serial, [
      'getprop',
      'ro.build.version.release',
    ])).output.trim();
    final installed = <String, int>{};
    for (final apk in apks) {
      final version = await _installed(phone.serial, apk);
      if (version != null) installed[apk.id] = version;
    }
    return UsbPhoneInfo(phone, sdk, release, Map.unmodifiable(installed));
  }

  List<BundledApk> recommended(UsbPhoneInfo info, List<BundledApk> apks) => [
    for (final apk in apks)
      if ((apk.id != 'nightzuku' || info.sdk >= 37) &&
          info.sdk >= apk.minSdk &&
          ((info.installed[apk.id] ?? -1) < apk.versionCode ||
              (apk.id == 'dexlink' &&
                  info.installed[apk.id] == apk.versionCode)))
        apk,
  ];

  Future<void> install(
    UsbPhoneInfo original,
    Set<String> selected, {
    required void Function(String message) onProgress,
  }) async {
    if (_installing) throw const UsbSetupException('安装正在进行中。');
    _installing = true;
    try {
      if (selected.isEmpty) throw const UsbSetupException('请先选择要安装的应用。');
      // Recheck the selected serial and versions just before the first write.
      final present = (await devices()).where(
        (p) => p.serial == original.phone.serial,
      );
      if (present.isEmpty || !present.first.ready) {
        throw const UsbSetupException('所选手机已断开或尚未允许 USB 调试。');
      }
      final info = await inspect(present.first);
      final apks = await packages();
      final ids = {...selected};
      if (ids.contains('nightzuku') && !info.installed.containsKey('shizuku')) {
        ids.add('shizuku');
      }
      if (!ids.every((id) => apks.any((apk) => apk.id == id))) {
        throw const UsbSetupException('未知安装包。');
      }
      final plan = [
        for (final apk in apks)
          if (ids.contains(apk.id)) apk,
      ];
      for (final apk in plan) {
        if (info.sdk < apk.minSdk) {
          throw UsbSetupException('${apk.label} 不支持这台手机的 Android 版本。');
        }
        if ((info.installed[apk.id] ?? -1) > apk.versionCode) {
          throw UsbSetupException('${apk.label} 已安装较新版本，已保留。');
        }
        await _verify(apk.file, apk.sha256);
      }
      for (final apk in plan) {
        onProgress('正在安装 ${apk.label}…请留意手机上的安装提示');
        final reply = await _run([
          '-s',
          info.phone.serial,
          'install',
          '-r',
          '--user',
          'current',
          p.join(directory.path, apk.file),
        ], timeout: const Duration(minutes: 3));
        if (reply.exitCode != 0 ||
            !RegExp(r'^Success\s*$', multiLine: true).hasMatch(reply.output) ||
            reply.output.contains('Failure [')) {
          throw UsbSetupException('${apk.label}：${_failure(reply.output)}');
        }
        final version = await _installed(info.phone.serial, apk);
        if (version == null || version < apk.versionCode) {
          throw UsbSetupException('${apk.label} 安装后未能确认，请检查手机安装提示。');
        }
        onProgress('${apk.label} 已安装');
      }
    } finally {
      _installing = false;
    }
  }

  static String _failure(String output) {
    if (output.contains('UPDATE_INCOMPATIBLE') ||
        output.contains('INCONSISTENT_CERTIFICATES')) {
      return '已有应用的签名不同，无法覆盖安装。请在手机上处理，现有应用已保留。';
    }
    if (output.contains('VERSION_DOWNGRADE')) return '手机已安装较新版本，已保留。';
    if (output.contains('USER_RESTRICTED') ||
        output.contains('USER_CANCELED')) {
      return '手机拒绝了安装，请允许 USB 安装并确认手机提示后重试。';
    }
    if (output.contains('INSUFFICIENT_STORAGE')) return '手机存储空间不足。';
    if (output.contains('unauthorized')) return '请在手机上允许这台电脑进行 USB 调试。';
    if (output.contains('offline') ||
        output.contains('not found') ||
        output.contains('no devices')) {
      return '手机已断开或离线，请重新连接后刷新。';
    }
    final failure = RegExp(r'Failure \[([^\]]+)\]').firstMatch(output);
    return failure == null ? 'USB 操作失败，请检查手机提示后重试。' : '安装失败：${failure[1]}';
  }
}
