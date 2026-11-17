import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// A network interface the PC may be able to reach.
class NetAddress {
  const NetAddress({required this.iface, required this.ip, required this.usb});

  final String iface;
  final String ip;

  /// True for an interface that looks like USB tethering (rndis0/usb0/eth0).
  final bool usb;

  factory NetAddress.fromMap(Map<dynamic, dynamic> map) => NetAddress(
    iface: '${map['iface']}',
    ip: '${map['ip']}',
    usb: map['usb'] == true,
  );
}

/// Snapshot of everything the native side knows.
class PhoneStatus {
  const PhoneStatus({
    required this.shizukuAvailable,
    required this.shizukuGranted,
    required this.running,
    required this.allFiles,
    required this.port,
    required this.sdk,
    this.shizukuInstalled = false,
    this.managerName = 'Shizuku',
    this.richInputEnabled = false,
    this.richInputSelected = false,
    this.adbEnabled = false,
    this.wirelessDebugging = false,
    this.accessibility = false,
    this.mode = 0,
    this.mirrorEngine = 'none',
    this.manufacturer = '',
    this.shizukuVersion,
    this.size,
    this.error,
    this.addresses = const [],
  });

  final bool shizukuAvailable;
  final bool shizukuGranted;
  final bool running;
  final bool allFiles;
  final int port;
  final int sdk;

  /// Whether the accessibility service (mirror-mode input) is switched on.
  final bool accessibility;

  /// 0 = desktop mode (virtual display), 1 = mirror mode.
  final int mode;
  final String mirrorEngine;

  /// `Build.MANUFACTURER`, used to tailor the ROM-specific permission guide.
  final String manufacturer;

  /// Shizuku the app is installed, whether or not its service is up.
  final bool shizukuInstalled;
  final String managerName;
  final bool richInputEnabled, richInputSelected;

  /// USB debugging / wireless debugging toggles, used to tailor the guide.
  final bool adbEnabled;
  final bool wirelessDebugging;

  final String? shizukuVersion;
  final String? size;
  final String? error;
  final List<NetAddress> addresses;

  static const empty = PhoneStatus(
    shizukuAvailable: false,
    shizukuGranted: false,
    running: false,
    allFiles: false,
    port: 27190,
    sdk: 0,
  );

  /// 0 = 没装, 1 = 装了没运行, 2 = 运行中未授权, 3 = 已授权。
  int get shizukuStage {
    if (!shizukuInstalled) return 0;
    if (!shizukuAvailable) return 1;
    if (!shizukuGranted) return 2;
    return 3;
  }

  factory PhoneStatus.fromMap(Map<dynamic, dynamic> map) => PhoneStatus(
    shizukuInstalled: map['shizukuInstalled'] == true,
    managerName: map['managerName'] as String? ?? 'Shizuku',
    richInputEnabled: map['richInputEnabled'] == true,
    richInputSelected: map['richInputSelected'] == true,
    shizukuAvailable: map['shizukuAvailable'] == true,
    shizukuGranted: map['shizukuGranted'] == true,
    running: map['running'] == true,
    allFiles: map['allFiles'] == true,
    adbEnabled: map['adbEnabled'] == true,
    wirelessDebugging: map['wirelessDebugging'] == true,
    accessibility: map['accessibility'] == true,
    mode: (map['mode'] as num?)?.toInt() ?? 0,
    mirrorEngine: map['mirrorEngine'] as String? ?? 'none',
    manufacturer: (map['manufacturer'] as String?) ?? '',
    port: (map['port'] as num?)?.toInt() ?? 27190,
    sdk: (map['sdk'] as num?)?.toInt() ?? 0,
    shizukuVersion: map['shizukuVersion'] as String?,
    size: map['size'] as String?,
    error: (map['error'] as String?)?.isEmpty ?? true
        ? null
        : map['error'] as String,
    addresses: ((map['addresses'] as List?) ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(NetAddress.fromMap)
        .toList(),
  );

  /// Applies a `shizuku` event pushed by the binder listeners.
  PhoneStatus withShizukuEvent(Map<String, dynamic> data) => PhoneStatus(
    shizukuInstalled: data['installed'] == true,
    managerName: data['managerName'] as String? ?? managerName,
    richInputEnabled: richInputEnabled,
    richInputSelected: richInputSelected,
    shizukuAvailable: data['running'] == true,
    shizukuGranted: data['granted'] == true,
    running: running,
    allFiles: allFiles,
    adbEnabled: data['adbEnabled'] == true,
    wirelessDebugging: data['wirelessDebugging'] == true,
    accessibility: accessibility,
    mode: mode,
    mirrorEngine: mirrorEngine,
    manufacturer: manufacturer,
    port: port,
    sdk: sdk,
    shizukuVersion: shizukuVersion,
    size: size,
    error: error,
    addresses: addresses,
  );

  PhoneStatus copyWith({
    bool? running,
    String? mirrorEngine,
    String? size,
    String? error,
    List<NetAddress>? addresses,
  }) => PhoneStatus(
    shizukuInstalled: shizukuInstalled,
    managerName: managerName,
    richInputEnabled: richInputEnabled,
    richInputSelected: richInputSelected,
    shizukuAvailable: shizukuAvailable,
    shizukuGranted: shizukuGranted,
    running: running ?? this.running,
    allFiles: allFiles,
    adbEnabled: adbEnabled,
    wirelessDebugging: wirelessDebugging,
    accessibility: accessibility,
    mode: mode,
    mirrorEngine: mirrorEngine ?? this.mirrorEngine,
    manufacturer: manufacturer,
    port: port,
    sdk: sdk,
    shizukuVersion: shizukuVersion,
    size: size ?? this.size,
    error: error,
    addresses: addresses ?? this.addresses,
  );
}

/// An event pushed from the native session.
class PhoneEvent {
  const PhoneEvent(this.type, this.data);

  final String type; // state | log | shizuku
  final Map<String, dynamic> data;

  String? get message => data['message'] as String?;
  String? get level => data['level'] as String?;
  int? get port => (data['port'] as num?)?.toInt();
  bool? get running => data['running'] as bool?;

  factory PhoneEvent.fromJson(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      return const PhoneEvent('log', {'message': 'invalid event'});
    }
    return PhoneEvent('${decoded['type'] ?? 'log'}', decoded);
  }
}

/// Dart side of `io.dexlink/phone`.
class PhoneBridge {
  static const MethodChannel _methods = MethodChannel('io.dexlink/phone');
  static const EventChannel _events = EventChannel('io.dexlink/phone/events');

  static Stream<PhoneEvent> get events => _events.receiveBroadcastStream().map(
    (event) => PhoneEvent.fromJson('$event'),
  );

  static Future<PhoneStatus> status() async {
    final map = await _methods.invokeMethod<Map<dynamic, dynamic>>('status');
    return map == null ? PhoneStatus.empty : PhoneStatus.fromMap(map);
  }

  static Future<void> requestShizuku() =>
      _methods.invokeMethod<void>('requestShizuku');

  /// Opens Shizuku if installed, otherwise its download page.
  static Future<void> openShizuku() =>
      _methods.invokeMethod<void>('openShizuku');

  static Future<void> openRichInputSettings() =>
      _methods.invokeMethod<void>('openRichInputSettings');
  static Future<void> chooseRichInput() =>
      _methods.invokeMethod<void>('chooseRichInput');

  static Future<void> openDeveloperOptions() =>
      _methods.invokeMethod<void>('openDeveloperOptions');

  static Future<void> openWirelessDebugging() =>
      _methods.invokeMethod<void>('openWirelessDebugging');

  static Future<void> openAccessibility() =>
      _methods.invokeMethod<void>('openAccessibility');

  /// The system app-info page, where "allow restricted settings" lives on ROMs
  /// that block accessibility for sideloaded apps.
  static Future<void> openAppSettings() =>
      _methods.invokeMethod<void>('openAppSettings');

  /// Shows the system screen-capture consent dialog; on approval the native
  /// side starts the mirror session by itself.
  static Future<void> startMirror() =>
      _methods.invokeMethod<void>('startMirror');

  static Future<void> openAllFilesAccess() =>
      _methods.invokeMethod<void>('openAllFilesAccess');

  /// MIUI/HyperOS blur the mirrored picture while "屏幕共享防护" is on; this
  /// jumps as close to that setting as the ROM allows.
  static Future<void> openScreenShareProtection() =>
      _methods.invokeMethod<void>('openScreenShareProtection');

  static Future<bool> screenShareProtectionConfirmed() async =>
      await _methods.invokeMethod<bool>('screenShareProtectionConfirmed') ??
      false;

  static Future<void> confirmScreenShareProtection(bool confirmed) =>
      _methods.invokeMethod<void>('confirmScreenShareProtection', confirmed);

  static Future<void> start({
    required int width,
    required int height,
    required int dpi,
    required int bitrate,
    bool newDisplay = true,
  }) => _methods.invokeMethod<void>('start', {
    'width': width,
    'height': height,
    'dpi': dpi,
    'bitrate': bitrate,
    'newDisplay': newDisplay,
  });

  static Future<void> stop() => _methods.invokeMethod<void>('stop');
}
