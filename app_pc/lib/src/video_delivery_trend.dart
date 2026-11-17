import 'dart:collection';

/// Arrival-time growth relative to source PTS, without synchronized clocks.
/// This is a queue trend, never absolute network latency or packet loss.
class VideoDeliveryTrend {
  final _points = Queue<({int arrival, int pts})>();

  void add(int arrivalUs, int ptsUs) {
    if (_points.isNotEmpty) {
      final last = _points.last;
      if (ptsUs <= last.pts ||
          ptsUs - last.pts > 250000 ||
          arrivalUs < last.arrival ||
          arrivalUs - last.arrival > 500000) {
        _points.clear();
      }
    }
    _points.add((arrival: arrivalUs, pts: ptsUs));
    while (_points.length > 128 || arrivalUs - _points.first.arrival > 750000) {
      _points.removeFirst();
    }
  }

  bool growing(int nowUs) {
    if (_points.length < 8 || nowUs - _points.last.arrival > 500000) {
      return false;
    }
    final first = _points.first, last = _points.last;
    final elapsed = last.arrival - first.arrival;
    if (elapsed < 300000) return false;
    // Least-squares growth smooths packet bursts. Constant offset, even a
    // large one, is not mistaken for a continuously worsening delivery path.
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (final point in _points) {
      final x = (point.arrival - first.arrival).toDouble();
      final y = (point.arrival - first.arrival - (point.pts - first.pts))
          .toDouble();
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final n = _points.length;
    final denominator = n * sxx - sx * sx;
    return denominator > 0 &&
        (n * sxy - sx * sy) / denominator * elapsed >= 40000;
  }
}
