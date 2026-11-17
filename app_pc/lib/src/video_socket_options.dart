import 'dart:io';
import 'dart:typed_data';

/// Transport capacity, not a playback queue: callers keep draining immediately.
int? configureVideoReceiveBuffer(Socket socket) {
  if (!Platform.isWindows) return null;
  const soRcvbuf = 0x1002; // Winsock SO_RCVBUF.
  try {
    socket.setRawOption(
      RawSocketOption.fromInt(
        RawSocketOption.levelSocket,
        soRcvbuf,
        512 * 1024,
      ),
    );
    final value = socket.getRawOption(
      RawSocketOption.fromInt(RawSocketOption.levelSocket, soRcvbuf, 0),
    );
    return ByteData.sublistView(value).getInt32(0, Endian.host);
  } on SocketException {
    return null;
  } on UnsupportedError {
    return null;
  }
}
