import 'dart:convert';
import 'dart:io';

import 'package:dex_link/dex_link.dart';

class ProjectionSettings {
  const ProjectionSettings({
    this.capture = const CaptureOptions(),
    this.screenOff = true,
    this.audio = true,
  });
  final CaptureOptions capture;
  final bool screenOff;
  final bool audio;
  static File get _file => File(
    '${Platform.environment['LOCALAPPDATA'] ?? Directory.current.path}/DexLink/projection.json',
  );

  static ProjectionSettings read({File? file}) {
    try {
      final json = jsonDecode((file ?? _file).readAsStringSync()) as Map;
      final options = CaptureOptions(
        maxSize: json['maxSize'] as int,
        bitrate: json['bitrate'] as int,
        features:
            const CaptureOptions().features |
            (json['preferHevc'] == true ? kCapturePreferHevc : 0),
      );
      options.validate();
      return ProjectionSettings(
        capture: options,
        screenOff: json['screenOff'] as bool,
        audio: json['audio'] as bool? ?? true,
      );
    } catch (_) {
      return const ProjectionSettings();
    }
  }

  Future<void> save({File? file}) async {
    capture.validate();
    final target = file ?? _file;
    await target.parent.create(recursive: true);
    await target.writeAsString(
      jsonEncode({
        'fps': capture.fps,
        'maxSize': capture.maxSize,
        'bitrate': capture.bitrate,
        'screenOff': screenOff,
        'audio': audio,
        'preferHevc': capture.features & kCapturePreferHevc != 0,
      }),
      flush: true,
    );
  }
}
