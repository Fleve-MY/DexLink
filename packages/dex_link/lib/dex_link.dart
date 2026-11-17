/// Wire protocol shared by the DexLink phone app and the DexLink PC client.
///
/// Video and control layouts are specified in docs/PROTOCOL.md. Capture,
/// encoding and input are implemented by the DexLink Android app.
library;

export 'src/byte_queue.dart';
export 'src/constants.dart';
export 'src/control_messages.dart';
export 'src/discovery.dart';
export 'src/video_stream.dart';
export 'src/capture_options.dart';
