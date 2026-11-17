import 'package:dex_link/dex_link.dart';

/// A short, complete prediction chain for asynchronous decoder startup.
class RecentVideoGop {
  RecentVideoGop({int Function()? nowUs}) {
    final clock = Stopwatch()..start();
    _nowUs = nowUs ?? () => clock.elapsedMicroseconds;
  }

  late final int Function() _nowUs;
  final _packets = <VideoPacket>[];
  int _started = 0, _bytes = 0;

  void clear() {
    _packets.clear();
    _bytes = 0;
  }

  void add(VideoPacket packet) {
    if (packet.config) {
      clear();
      return;
    }
    if (packet.keyFrame) {
      clear();
      _started = _nowUs();
    } else if (_packets.isEmpty) {
      return;
    }
    if (_nowUs() - _started >= 300000 ||
        (_packets.isNotEmpty && packet.pts - _packets.first.pts >= 300000) ||
        _packets.length >= 120 ||
        _bytes + packet.data.length > 4 * 1024 * 1024) {
      clear();
      return;
    }
    _packets.add(packet);
    _bytes += packet.data.length;
  }

  List<VideoPacket> replay() {
    if (_nowUs() - _started >= 300000) clear();
    return List.of(_packets);
  }
}
