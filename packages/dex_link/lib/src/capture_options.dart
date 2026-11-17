import 'dart:typed_data';

const kCaptureOptionsVersion = 2;
const kCaptureTelemetry = 1;
const kCaptureAdaptiveBitrate = 2;
const kCaptureAppWindows = 4;
const kCapturePreferHevc = 8;

/// Initial capture settings, negotiated on Q before the video/control sockets.
class CaptureOptions {
  const CaptureOptions({
    this.fps = 60,
    this.maxSize = 1920,
    this.bitrate = 12000000,
    this.features = kCaptureTelemetry | kCaptureAdaptiveBitrate | kCaptureAppWindows,
  });
  final int fps;
  final int maxSize;
  final int bitrate;
  final int features;

  void validate() {
    if ((fps != 0 && fps < 15) ||
        fps > 120 ||
        maxSize < 640 ||
        maxSize > 3840 ||
        bitrate < 2000000 ||
        bitrate > 50000000 ||
        features < 0 ||
        features > 15) {
      throw ArgumentError('Invalid capture settings');
    }
  }

  Uint8List request() {
    validate();
    final bytes = ByteData(21)
      ..setUint8(0, 0x51)
      ..setUint32(1, kCaptureOptionsVersion)
      ..setUint32(5, fps)
      ..setUint32(9, maxSize)
      ..setUint32(13, bitrate)
      ..setUint32(17, features);
    return bytes.buffer.asUint8List();
  }
}
