import 'dart:typed_data';

/// A growable FIFO of bytes with cheap fixed-size peeks.
///
/// Network sockets hand us arbitrary chunk boundaries, so every parser in this
/// package is written against this queue instead of buffering whole packets by
/// hand.
class ByteQueue {
  ByteQueue([int initialCapacity = 64 * 1024])
    : _buffer = Uint8List(initialCapacity);

  Uint8List _buffer;
  int _start = 0;
  int _end = 0;

  /// Number of bytes currently buffered.
  int get length => _end - _start;

  bool get isEmpty => length == 0;

  /// Appends [bytes].
  void add(Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (_buffer.length - _end < bytes.length) {
      _compact(bytes.length);
    }
    _buffer.setRange(_end, _end + bytes.length, bytes);
    _end += bytes.length;
  }

  /// Whether at least [count] bytes are buffered.
  bool has(int count) => length >= count;

  /// Consumes [count] bytes and returns them as a fresh, right-sized array.
  Uint8List readBytes(int count) {
    if (count > length) {
      throw StateError('ByteQueue underflow: want $count, have $length');
    }
    final out = Uint8List.fromList(
      Uint8List.sublistView(_buffer, _start, _start + count),
    );
    _start += count;
    _normalize();
    return out;
  }

  /// Consumes [count] bytes without copying.
  void skip(int count) {
    if (count > length) {
      throw StateError('ByteQueue underflow: want $count, have $length');
    }
    _start += count;
    _normalize();
  }

  /// Unsigned byte at [offset] (no consume).
  int peekUint8(int offset) {
    _requirePeek(offset + 1);
    return _buffer[_start + offset];
  }

  /// Big-endian int32 at [offset] from the current read position (no consume).
  int peekInt32(int offset) {
    _requirePeek(offset + 4);
    return _data.getInt32(_start + offset, Endian.big);
  }

  /// Big-endian uint16 at [offset] (no consume).
  int peekUint16(int offset) {
    _requirePeek(offset + 2);
    return _data.getUint16(_start + offset, Endian.big);
  }

  /// Big-endian int64 at [offset] (no consume).
  int peekInt64(int offset) {
    _requirePeek(offset + 8);
    return _data.getInt64(_start + offset, Endian.big);
  }

  ByteData get _data => ByteData.sublistView(_buffer);

  void _requirePeek(int count) {
    if (count > length) {
      throw StateError('ByteQueue underflow: want $count, have $length');
    }
  }

  /// Drops the consumed prefix once it dominates the buffer.
  void _normalize() {
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
  }

  void _compact(int incoming) {
    final live = length;
    if (_start == 0) {
      // Nothing consumed yet: the buffer is simply too small.
      final grown = Uint8List(_grow(live + incoming));
      grown.setRange(0, _end, _buffer);
      _buffer = grown;
      return;
    }
    // Move the live bytes to the front and reuse the allocation.
    _buffer.setRange(0, live, _buffer, _start);
    _start = 0;
    _end = live;
    if (_buffer.length - _end < incoming) {
      final grown = Uint8List(_grow(live + incoming));
      grown.setRange(0, live, _buffer);
      _buffer = grown;
    }
  }

  int _grow(int needed) {
    var capacity = _buffer.isEmpty ? 64 * 1024 : _buffer.length;
    while (capacity < needed) {
      capacity *= 2;
    }
    return capacity;
  }
}
