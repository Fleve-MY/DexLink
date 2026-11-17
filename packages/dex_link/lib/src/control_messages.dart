import 'dart:convert';
import 'dart:typed_data';

import 'byte_queue.dart';
import 'constants.dart';

/// Serializes the control messages the PC client sends to the phone.
///
/// Byte layout is defined by docs/PROTOCOL.md and decoded by DexLink Android.
abstract final class ControlMessages {
  static Uint8List videoBitrate(int bitrate) {
    if (bitrate < 2000000 || bitrate > 50000000) {
      throw ArgumentError.value(bitrate, 'bitrate');
    }
    return (_Writer()
          ..u8(24)
          ..i32(bitrate))
        .take();
  }

  static Uint8List desktop(Map<String, Object> request) {
    final w = _Writer()..u8(23);
    w.string32(jsonEncode(request));
    return w.take();
  }

  static Uint8List resetVideo() => Uint8List.fromList([ControlType.resetVideo]);

  static Uint8List injectKeycode({
    required int action,
    required int keycode,
    int repeat = 0,
    int metaState = MetaState.none,
  }) {
    final w = _Writer();
    w.u8(ControlType.injectKeycode);
    w.u8(action);
    w.i32(keycode);
    w.i32(repeat);
    w.i32(metaState);
    return w.take();
  }

  static Uint8List injectText(String text) {
    final w = _Writer();
    w.u8(ControlType.injectText);
    w.string32(text);
    return w.take();
  }

  /// `x`/`y` are in the coordinate space of [screenWidth] x [screenHeight].
  static Uint8List injectTouch({
    required int action,
    required int pointerId,
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
    double pressure = 1.0,
    int actionButton = 0,
    int buttons = 0,
  }) {
    final w = _Writer();
    w.u8(ControlType.injectTouch);
    w.u8(action);
    w.i64(pointerId);
    w.position(x, y, screenWidth, screenHeight);
    w.u16(_u16FixedPoint(pressure));
    w.i32(actionButton);
    w.i32(buttons);
    return w.take();
  }

  /// [hScroll]/[vScroll] are in the protocol's [-16, 16] unit range.
  static Uint8List injectScroll({
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
    required double hScroll,
    required double vScroll,
    int buttons = 0,
  }) {
    final w = _Writer();
    w.u8(ControlType.injectScroll);
    w.position(x, y, screenWidth, screenHeight);
    w.u16(_i16FixedPoint(hScroll / 16.0) & 0xFFFF);
    w.u16(_i16FixedPoint(vScroll / 16.0) & 0xFFFF);
    w.i32(buttons);
    return w.take();
  }

  static Uint8List backOrScreenOn(int action) =>
      Uint8List.fromList([ControlType.backOrScreenOn, action]);

  static Uint8List getClipboard({bool copyKey = false}) =>
      Uint8List.fromList([ControlType.getClipboard, copyKey ? 1 : 0]);

  static Uint8List setClipboard({
    required int sequence,
    required String text,
    bool paste = false,
  }) {
    final w = _Writer();
    w.u8(ControlType.setClipboard);
    w.i64(sequence);
    w.u8(paste ? 1 : 0);
    w.string32(text);
    return w.take();
  }

  static Uint8List setDisplayPower(bool on) =>
      Uint8List.fromList([ControlType.setDisplayPower, on ? 1 : 0]);

  static Uint8List rotateDevice() =>
      Uint8List.fromList([ControlType.rotateDevice]);

  static Uint8List expandNotificationPanel() =>
      Uint8List.fromList([ControlType.expandNotificationPanel]);

  static Uint8List expandSettingsPanel() =>
      Uint8List.fromList([ControlType.expandSettingsPanel]);

  static Uint8List collapsePanels() =>
      Uint8List.fromList([ControlType.collapsePanels]);

  /// Launches an app on the display being streamed.
  /// [name] is a package name or `package/activity`.
  static Uint8List startApp(String name) {
    final w = _Writer();
    w.u8(ControlType.startApp);
    w.string8(name);
    return w.take();
  }

  static Uint8List resizeDisplay({required int width, required int height}) {
    final w = _Writer();
    w.u8(ControlType.resizeDisplay);
    w.u16(width);
    w.u16(height);
    return w.take();
  }

  static Uint8List scanFile(String path) {
    final w = _Writer();
    w.u8(ControlType.scanFile);
    w.string32(path);
    return w.take();
  }

  static Uint8List openHardKeyboardSettings() =>
      Uint8List.fromList([ControlType.openHardKeyboardSettings]);

  /// `Binary.u16FixedPointToFloat()` (0xFFFF means exactly 1.0).
  static int _u16FixedPoint(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped >= 1.0) return 0xFFFF;
    return (clamped * 0x10000).round();
  }

  /// `Binary.i16FixedPointToFloat()`: 0x7FFF means exactly 1.0.
  static int _i16FixedPoint(double value) {
    final clamped = value.clamp(-1.0, 1.0);
    if (clamped >= 1.0) return 0x7FFF;
    return (clamped * 0x8000).round();
  }
}

/// Messages the phone pushes back on the control socket.
sealed class DeviceMessage {
  const DeviceMessage();
}

class ClipboardText extends DeviceMessage {
  const ClipboardText(this.text);
  final String text;
}

class ClipboardAck extends DeviceMessage {
  const ClipboardAck(this.sequence);
  final int sequence;
}

class PanelPowerResult extends DeviceMessage {
  const PanelPowerResult(this.on, this.success);
  final bool on;
  final bool success;
}

class DesktopMessage extends DeviceMessage {
  const DesktopMessage(this.data);
  final Map<String, dynamic> data;
}

class CaptureTelemetry extends DeviceMessage {
  const CaptureTelemetry(this.data);
  final Map<String, dynamic> data;
}

class VideoBitrateResult extends DeviceMessage {
  const VideoBitrateResult(this.data);
  final Map<String, dynamic> data;
}

class UhidOutput extends DeviceMessage {
  const UhidOutput(this.id, this.data);
  final int id;
  final Uint8List data;
}

/// Incremental parser for the device -> client direction.
class DeviceMessageParser {
  ByteQueue _queue = ByteQueue(4096);
  bool _failed = false;
  bool get failed => _failed;

  List<DeviceMessage> parse(Uint8List chunk) {
    if (_failed) return const [];
    try {
      return _parse(chunk);
    } catch (_) {
      // Unknown layouts cannot be skipped safely. Fail once, release buffered
      // data and leave the independent video/downlink paths working.
      _failed = true;
      _queue = ByteQueue(0);
      rethrow;
    }
  }

  List<DeviceMessage> _parse(Uint8List chunk) {
    _queue.add(chunk);
    final out = <DeviceMessage>[];
    while (_queue.has(1)) {
      final type = _queue.peekUint8(0);
      switch (type) {
        case 21:
        case 24:
        case 25:
          if (!_queue.has(5)) return out;
          final len = _queue.peekInt32(1);
          if (len < 0 || len > 1 << 20) {
            throw FormatException('Invalid desktop message length: $len');
          }
          if (!_queue.has(5 + len)) return out;
          _queue.skip(5);
          final data = jsonDecode(utf8.decode(_queue.readBytes(len)));
          if (data is! Map<String, dynamic>) {
            throw const FormatException('Invalid desktop response');
          }
          out.add(switch (type) {
            24 => CaptureTelemetry(data),
            25 => VideoBitrateResult(data),
            _ => DesktopMessage(data),
          });
        case DeviceMessageType.panelPowerResult:
          if (!_queue.has(3)) return out;
          out.add(
            PanelPowerResult(
              _queue.peekUint8(1) != 0,
              _queue.peekUint8(2) != 0,
            ),
          );
          _queue.skip(3);
        case DeviceMessageType.clipboard:
          if (!_queue.has(5)) return out;
          final len = _queue.peekInt32(1);
          if (len < 0 || len > 1 << 18) {
            throw FormatException('Invalid clipboard length: $len');
          }
          if (!_queue.has(5 + len)) return out;
          _queue.skip(5);
          final bytes = _queue.readBytes(len);
          out.add(ClipboardText(utf8.decode(bytes, allowMalformed: true)));
        case DeviceMessageType.ackClipboard:
          if (!_queue.has(9)) return out;
          final seq = _queue.peekInt64(1);
          _queue.skip(9);
          out.add(ClipboardAck(seq));
        case DeviceMessageType.uhidOutput:
          if (!_queue.has(5)) return out;
          final id = _queue.peekUint16(1);
          final len = _queue.peekUint16(3);
          if (!_queue.has(5 + len)) return out;
          _queue.skip(5);
          out.add(UhidOutput(id, _queue.readBytes(len)));
        default:
          throw FormatException('Unknown device message type: $type');
      }
    }
    return out;
  }
}

/// Big-endian writer for the small, fixed-layout control messages.
class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: true);

  void u8(int value) => _builder.addByte(value & 0xFF);

  void u16(int value) {
    final data = ByteData(2)..setUint16(0, value & 0xFFFF, Endian.big);
    _builder.add(data.buffer.asUint8List());
  }

  void i32(int value) {
    final data = ByteData(4)..setInt32(0, value, Endian.big);
    _builder.add(data.buffer.asUint8List());
  }

  void i64(int value) {
    final data = ByteData(8)..setInt64(0, value, Endian.big);
    _builder.add(data.buffer.asUint8List());
  }

  void position(int x, int y, int screenWidth, int screenHeight) {
    i32(x);
    i32(y);
    u16(screenWidth);
    u16(screenHeight);
  }

  /// uint32 length prefix + UTF-8 payload.
  void string32(String value) {
    final bytes = utf8.encode(value);
    i32(bytes.length);
    _builder.add(bytes);
  }

  /// uint8 length prefix + UTF-8 payload, truncated to 255 bytes.
  void string8(String value) {
    var bytes = utf8.encode(value);
    if (bytes.length > 255) bytes = bytes.sublist(0, 255);
    u8(bytes.length);
    _builder.add(bytes);
  }

  Uint8List take() => _builder.takeBytes();
}
