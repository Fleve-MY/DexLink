/// Excess transit time relative to the fastest observed sample. Clocks need
/// not agree; this cannot measure absolute one-way network latency.
class TelemetryFreshness {
  int? _minimumOffset, _lastSource;

  bool accept(int arrivalMs, int? sourceMs) {
    // Old phones have no source timestamp. Batch coalescing still applies.
    if (sourceMs == null) return true;
    if (_lastSource != null && sourceMs <= _lastSource!) return false;
    _lastSource = sourceMs;
    final offset = arrivalMs - sourceMs;
    if (_minimumOffset == null || offset < _minimumOffset!) {
      _minimumOffset = offset;
    }
    return offset - _minimumOffset! <= 250;
  }
}
