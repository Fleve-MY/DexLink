import 'dart:io';

/// A plain text log of everything the window had to say about a session.
///
/// The banner inside the window is capped in height and disappears with the
/// window, which is no help for "it failed again, what did it say". Every line
/// that reaches the banner is also appended here, so the file can simply be
/// opened and read after the fact:
///
///   %LOCALAPPDATA%\DexLink\dexlink.log
///
/// A line is written the moment it is produced, not buffered until exit: a
/// window that is force-closed, or that never gets past `main`, still leaves
/// its first line behind — and that first line is the only proof of which
/// build actually ran. If the preferred folder is not writable the log falls
/// back to the folder next to the exe and then to the temp directory instead
/// of silently dropping every line; [path] always says where the lines went.
///
/// Rotated by size only (one `.1` generation): a log nobody ever truncates
/// would otherwise grow for the life of the installation.
class SessionLog {
  const SessionLog._();

  static const int _maxBytes = 512 * 1024;

  static String? _path;

  /// Where the lines are going; `debugState` shows it so it can be found
  /// without guessing.
  ///
  /// Resolves on demand: before the first write, `_path` is still null and a
  /// getter that just answered "unavailable" would hide a working log.
  static String get path {
    _path ??= _resolvePath();
    return _path ?? '（日志不可用）';
  }

  static List<String> _candidates() {
    final local = Platform.environment['LOCALAPPDATA'];
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // One file per executable folder, not one shared file. A self-test run from
    // build\ and the real app run from dist\ otherwise append to the same file,
    // and the fake-phone traffic buries the session that actually matters --
    // which is precisely how "there is no record of my phone" happened while
    // the log looked busy.
    final tag = _tagFor(exeDir);
    return <String>[
      if (local != null && local.isNotEmpty)
        '$local\\DexLink\\dexlink$tag.log',
      if (exeDir.isNotEmpty) '$exeDir\\dexlink$tag.log',
      '${Directory.systemTemp.path}\\dexlink$tag.log',
    ];
  }

  /// Distinguishes builds without putting anything unruly in a file name.
  static String _tagFor(String exeDir) {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return '-test';
    if (Platform.environment['DEXLINK_LOG_TAG'] case final String forced
        when forced.isNotEmpty) {
      return '-$forced';
    }
    if (exeDir.contains('${Platform.pathSeparator}build${Platform.pathSeparator}')) {
      return '-build';
    }
    return '';
  }

  /// First location whose folder can be created, i.e. one that can actually
  /// be appended to. Existence and permission are not the same problem on
  /// Windows, so this probes the folder rather than asking `existsSync`.
  static String? _resolvePath() {
    for (final candidate in _candidates()) {
      try {
        File(candidate).parent.createSync(recursive: true);
        // Creating the folder proves nothing: it can exist from an earlier run
        // while the file inside it is read-only, owned by another user, or on
        // a drive that just went away. Open it for append once, right here.
        File(candidate).writeAsStringSync('', mode: FileMode.append);
        return candidate;
      } catch (error) {
        // Remember why, so the window can say it instead of silently writing
        // nowhere while the user reports "there is no log".
        _lastFailure = '${File(candidate).path}: $error';
        continue;
      }
    }
    return null;
  }

  static String? _lastFailure;

  /// Why logging is not working, for the debug panel. Null when it works.
  static String? get failure => _path == null ? (_lastFailure ?? '无可用路径') : null;

  /// Appends one line. Never throws: logging must not be able to break a
  /// connection attempt.
  ///
  /// A resolved path is not a promise. The file can be locked by another copy
  /// of the app, sit on a drive that was unplugged, or lose its permissions --
  /// and if the chosen path then failed silently every later line went nowhere
  /// while [path] still claimed it was fine. A failed write therefore clears the
  /// cached path, so the next line runs down the candidate list again instead of
  /// repeating a write that is known to fail.
  static void write(String message) {
    final stamp = DateTime.now();
    final line =
        '${_two(stamp.hour)}:${_two(stamp.minute)}:${_two(stamp.second)} '
        '$message\n';
    if (_path == null) {
      _path = _resolvePath();
      if (_path == null) return;
    }
    try {
      final file = File(_path!);
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        final rotated = File('${file.path}.1');
        if (rotated.existsSync()) rotated.deleteSync();
        file.renameSync(rotated.path);
      }
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (error) {
      _lastFailure = '$_path: $error';
      // Give up on this path so the next line tries the next candidate.
      _path = null;
    }
  }

  /// Reads the current session log content.
  static String read() {
    if (_path == null) {
      _path = _resolvePath();
      if (_path == null) return '';
    }
    try {
      final file = File(_path!);
      if (file.existsSync()) {
        return file.readAsStringSync();
      }
    } catch (_) {}
    return '';
  }

  /// Clears the current session log.
  static void clear() {
    if (_path == null) {
      _path = _resolvePath();
      if (_path == null) return;
    }
    try {
      final file = File(_path!);
      if (file.existsSync()) {
        file.writeAsStringSync('');
      }
    } catch (_) {}
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
