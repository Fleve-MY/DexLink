import 'dart:convert';
import 'dart:typed_data';

import 'byte_queue.dart';
import 'constants.dart';

/// The stream prologue sent once on the video socket.
class VideoStreamInfo {
  const VideoStreamInfo({
    required this.deviceName,
    required this.codecId,
    required this.width,
    required this.height,
    required this.clientResize,
    this.panelPower = false,
    this.frameRate = 60,
    this.unlimited = false,
    this.desktopControl = false,
    this.adaptiveBitrate = false,
    this.appWindows = false,
    this.dynamicSize = false,
    this.realtimeVideo = false,
  });

  final String deviceName;
  final int codecId;
  final int width;
  final int height;

  /// True when the width/height were chosen by the client (a virtual display
  /// created in desktop mode), false when they describe the real panel.
  final bool clientResize;
  final bool panelPower;
  final int frameRate;
  final bool unlimited;
  final bool desktopControl;
  final bool adaptiveBitrate;
  final bool appWindows;
  final bool dynamicSize;
  final bool realtimeVideo;
  String get frameRateLabel => unlimited ? '无帧率上限' : '上限 $frameRate FPS';

  bool get isH264 => codecId == kCodecH264;
  bool get isH265 => codecId == kCodecH265;

  String get codecName => switch (codecId) {
    kCodecH264 => 'H.264',
    kCodecH265 => 'H.265',
    kCodecAv1 => 'AV1',
    _ => '0x${codecId.toRadixString(16)}',
  };

  @override
  String toString() =>
      'VideoStreamInfo($deviceName, $codecName, ${width}x$height, clientResize: $clientResize)';
}

/// One encoded video packet from the phone encoder.
class VideoPacket {
  const VideoPacket({
    required this.data,
    required this.pts,
    required this.config,
    required this.keyFrame,
  });

  /// Encoded payload. For a config packet this is the codec configuration
  /// (SPS/PPS for H.264) that the decoder needs before the first frame.
  final Uint8List data;

  /// Presentation timestamp in microseconds; 0 for config packets.
  final int pts;

  final bool config;
  final bool keyFrame;

  @override
  String toString() =>
      'VideoPacket(${data.length}b, pts: $pts, config: $config, key: $keyFrame)';
}

sealed class VideoEvent {
  const VideoEvent();
}

class VideoStreamStarted extends VideoEvent {
  const VideoStreamStarted(this.info);
  final VideoStreamInfo info;
}

class VideoFrameReceived extends VideoEvent {
  const VideoFrameReceived(this.packet);
  final VideoPacket packet;
}

class VideoStreamError extends VideoEvent {
  const VideoStreamError(this.message);
  final String message;
}

/// Incremental parser for the DexLink video channel.
///
/// Wire format (all integers big endian):
///
/// ```text
/// [64] device name, UTF-8, NUL padded
/// [ 4] codec id
/// [12] session meta: flags, width, height
/// then, repeated:
/// [ 8] pts | flags
/// [ 4] payload size
/// [ n] payload
/// ```
///
/// DexLink always sends codec and session metadata and rejects streams without it.
class VideoStreamParser {
  VideoStreamParser({this.maxPacketSize = kMaxVideoPacketSize});

  final int maxPacketSize;

  final ByteQueue _queue = ByteQueue();
  int _stage = 0;

  bool get _hasHeader => _stage >= 3;

  /// Feeds raw socket bytes and returns every complete event they produced.
  List<VideoEvent> parse(Uint8List chunk) {
    _queue.add(chunk);
    final events = <VideoEvent>[];

    while (true) {
      switch (_stage) {
        case 0: // device name
          if (!_queue.has(kDeviceNameLength)) return events;
          final raw = _queue.readBytes(kDeviceNameLength);
          final nul = raw.indexOf(0);
          final nameBytes = nul == -1
              ? raw
              : Uint8List.sublistView(raw, 0, nul);
          _deviceName = utf8.decode(nameBytes, allowMalformed: true);
          _stage = 1;
        case 1: // codec id
          if (!_queue.has(4)) return events;
          _codecId = _queue.peekInt32(0);
          _queue.skip(4);
          _stage = 2;
        case 2: // session meta
          if (!_queue.has(12)) return events;
          final flags = _queue.peekInt32(0);
          final width = _queue.peekInt32(4);
          final height = _queue.peekInt32(8);
          _queue.skip(12);
          if (width <= 0 || height <= 0) {
            events.add(
              VideoStreamError(
                'Rejected stream with invalid size ${width}x$height',
              ),
            );
            _stage = 99;
            return events;
          }
          _stage = 3;
          events.add(
            VideoStreamStarted(
              VideoStreamInfo(
                deviceName: _deviceName,
                codecId: _codecId,
                width: width,
                height: height,
                // The session flag's low bit means "sized by the client".
                clientResize: (flags & 1) != 0,
                panelPower: (flags & 2) != 0,
                unlimited: (flags & 4) != 0,
                desktopControl: (flags & 8) != 0,
                adaptiveBitrate: (flags & 16) != 0,
                appWindows: (flags & 32) != 0,
                dynamicSize: (flags & 64) != 0,
                realtimeVideo: (flags & 128) != 0,
                frameRate: ((flags >> 8) & 255) == 0
                    ? 60
                    : ((flags >> 8) & 255),
              ),
            ),
          );
        case 3: // packets
          if (!_queue.has(kFrameHeaderLength)) return events;
          final ptsAndFlags = _queue.peekInt64(0);
          final size = _queue.peekInt32(8);
          if (size < 0 || size > maxPacketSize) {
            events.add(VideoStreamError('Invalid packet size: $size'));
            _stage = 99;
            return events;
          }
          if (!_queue.has(kFrameHeaderLength + size)) return events;
          _queue.skip(kFrameHeaderLength);
          final payload = size == 0 ? Uint8List(0) : _queue.readBytes(size);
          events.add(
            VideoFrameReceived(
              VideoPacket(
                data: payload,
                pts: ptsAndFlags & 0x1FFFFFFFFFFFFF,
                config: (ptsAndFlags & kFrameFlagConfig) != 0,
                keyFrame: (ptsAndFlags & kFrameFlagKeyFrame) != 0,
              ),
            ),
          );
        default:
          // Poisoned: swallow everything, the connection is being torn down.
          _queue.skip(_queue.length);
          return events;
      }
    }
  }

  late String _deviceName;
  late int _codecId;

  /// True once the prologue has been consumed.
  bool get isStarted => _hasHeader;
}
