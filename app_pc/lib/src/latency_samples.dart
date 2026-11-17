/// Bounded rolling samples. Callers use their own monotonic session clock.
class LatencySamples {
  LatencySamples({this.capacity = 256}) : assert(capacity > 0);
  final int capacity;
  final List<({int atUs, int durationUs})> _samples = [];
  int _next = 0;
  void clear() {
    _samples.clear();
    _next = 0;
  }

  void add(int atUs, int durationUs) {
    final sample = (atUs: atUs, durationUs: durationUs);
    if (_samples.length < capacity) {
      _samples.add(sample);
    } else {
      _samples[_next] = sample;
    }
    _next = (_next + 1) % capacity;
  }

  Map<String, Object> snapshot(int nowUs) {
    if (_samples.isEmpty) return {'n': 0};
    final values = _samples.map((s) => s.durationUs).toList()..sort();
    final oldest = _samples.map((s) => s.atUs).reduce((a, b) => a < b ? a : b);
    final newest = _samples.map((s) => s.atUs).reduce((a, b) => a > b ? a : b);
    double percentile(int percent) =>
        values[((values.length * percent + 99) ~/ 100) - 1] / 1000;
    return {
      'n': values.length,
      'windowMs': (newest - oldest) / 1000,
      'ageMs': (nowUs - newest) / 1000,
      'p50Ms': percentile(50),
      'p99Ms': percentile(99),
      'maxMs': values.last / 1000,
    };
  }
}
