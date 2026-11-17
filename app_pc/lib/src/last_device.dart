import 'dart:io';

/// Remembers the last phone the user connected to.
///
/// Auto-discovery can legitimately fail (different subnet, VPN, firewall) and
/// typing an address is the thing we are trying to avoid, so the last working
/// address gets offered as a one-click card.
class LastDeviceStore {
  static File _file() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.current.path;
    return File('$base\\DexLink\\last_device.txt');
  }

  static Future<String?> read() async {
    try {
      final file = _file();
      if (!await file.exists()) return null;
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String host, int port) async {
    try {
      final file = _file();
      await file.parent.create(recursive: true);
      await file.writeAsString('$host:$port');
    } catch (_) {
      // Losing the hint is not worth surfacing.
    }
  }
}
