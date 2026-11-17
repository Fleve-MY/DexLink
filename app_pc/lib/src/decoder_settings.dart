import 'dart:io';

enum DecoderMode {
  auto('自动（优先硬解）'),
  hardware('硬件解码'),
  software('软件解码');

  const DecoderMode(this.label);
  final String label;

  static DecoderMode parse(String? value) =>
      values.firstWhere((mode) => mode.name == value, orElse: () => auto);
}

class DecoderSettings {
  static File get _file {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
    return File(
      '$base${Platform.pathSeparator}DexLink${Platform.pathSeparator}decoder.txt',
    );
  }

  static DecoderMode read({File? file}) {
    try {
      return DecoderMode.parse((file ?? _file).readAsStringSync().trim());
    } catch (_) {
      return DecoderMode.auto;
    }
  }

  static Future<void> write(DecoderMode mode, {File? file}) async {
    final target = file ?? _file;
    await target.parent.create(recursive: true);
    await target.writeAsString(mode.name, flush: true);
  }
}
