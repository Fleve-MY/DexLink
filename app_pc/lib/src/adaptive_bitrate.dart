/// Fast decrease, slow recovery. FPS and resolution are never changed.
class AdaptiveBitrate {
  AdaptiveBitrate(this.ceiling) : current = ceiling;
  final int ceiling;
  int current;
  int? _badSince, _healthySince, _lastSample;
  int? _changedAt;
  int? _pending;
  int? _pendingAt;
  int _failures = 0, _retryAt = 0;

  // The phone can reduce locally while Wi-Fi delays its telemetry/our command.
  // Never overwrite an outstanding command with an older telemetry snapshot.
  void observeSenderBitrate(int bitrate, int nowMs) {
    if (_pending != null || bitrate < 2000000 || bitrate >= current) return;
    current = bitrate;
    _changedAt = nowMs;
    _badSince = _healthySince = null;
  }

  int? sample({
    required int nowMs,
    required bool active,
    required double oldestMs,
    required bool sendingSlowly,
    bool urgent = false,
    bool allowIncrease = true,
  }) {
    if (_lastSample != null && nowMs - _lastSample! > 1500) {
      _badSince = _healthySince = null;
    }
    _lastSample = nowMs;
    if (_pending != null) {
      if (nowMs - _pendingAt! >= 3000) _failed(nowMs);
      return null;
    }
    if (!active) {
      _badSince = _healthySince = null;
      return null;
    }
    final bad = oldestMs >= 50 || sendingSlowly || urgent;
    _badSince = bad ? (_badSince ?? nowMs) : null;
    _healthySince = !bad && allowIncrease && oldestMs < 16
        ? (_healthySince ?? nowMs)
        : null;
    if (nowMs < _retryAt) return null;
    final floor = (ceiling ~/ 4).clamp(2000000, ceiling);
    int? next;
    if (_badSince != null &&
        (urgent || nowMs - _badSince! >= 100) &&
        (_changedAt == null || nowMs - _changedAt! >= 500) &&
        current > floor) {
      next = (current * .8).round().clamp(floor, ceiling);
    } else if (_healthySince != null &&
        nowMs - _healthySince! >= 8000 &&
        (_changedAt == null || nowMs - _changedAt! >= 8000) &&
        current < ceiling) {
      next = (current + ceiling ~/ 20).clamp(floor, ceiling);
    }
    if (next == null) return null;
    _pending = next;
    _pendingAt = _changedAt = nowMs;
    _badSince = _healthySince = null;
    return next;
  }

  void acknowledge({required bool success, required int bitrate}) {
    if (_pending == null) return;
    if (!success) {
      _failed(_lastSample ?? _pendingAt!);
      return;
    }
    // Ignore a delayed acknowledgement for an earlier, timed-out request.
    if (bitrate < 2000000 || bitrate > _pending!) return;
    current = bitrate;
    _failures = 0;
    _pending = null;
    _pendingAt = null;
  }

  void _failed(int nowMs) {
    _pending = _pendingAt = null;
    _badSince = _healthySince = null;
    _failures = (_failures + 1).clamp(1, 5);
    _retryAt = nowMs + (1000 << _failures).clamp(2000, 30000);
  }
}
