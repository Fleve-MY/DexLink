import 'dart:io';

/// Small on-disk settings that belong to the window, not to a session.
///
/// One key per line in `%LOCALAPPDATA%\DexLink\settings.txt`, next to the
/// last-device hint. A whole settings framework would be more code than
/// settings: these are switches the user flips once and expects to stick.
class ViewOptionsStore {
  const ViewOptionsStore._();

  static File _file() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.current.path;
    return File('$base\\DexLink\\settings.txt');
  }

  static Map<String, String> _read() {
    try {
      final file = _file();
      if (!file.existsSync()) return <String, String>{};
      final result = <String, String>{};
      for (final line in file.readAsLinesSync()) {
        final index = line.indexOf('=');
        if (index <= 0) continue;
        result[line.substring(0, index).trim()] =
            line.substring(index + 1).trim();
      }
      return result;
    } catch (_) {
      return <String, String>{};
    }
  }

  static void _write(String key, String value) {
    try {
      final file = _file();
      file.parent.createSync(recursive: true);
      final values = _read()..[key] = value;
      file.writeAsStringSync(
        values.entries.map((e) => '${e.key}=${e.value}').join('\n'),
        flush: true,
      );
    } catch (_) {
      // A lost preference is not worth interrupting the session for.
    }
  }

  /// Whether the window should be shaped like the phone.
  ///
  /// Defaults to on, which is what a phone-companion window looks like out of
  /// the box: a portrait phone becomes a tall window at the right edge of the
  /// screen, and the picture fills it exactly. It stays an option (⋮ menu,
  /// F11) because a window that resizes itself against the user's wishes is
  /// worse than one that does not; an explicit `false` is remembered.
  static bool readSizeToPhone() {
    final stored = _read()['sizeToPhone'];
    return stored == null ? true : stored == 'true';
  }

  static void writeSizeToPhone(bool value) =>
      _write('sizeToPhone', value ? 'true' : 'false');
}
