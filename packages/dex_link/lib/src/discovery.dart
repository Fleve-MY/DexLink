import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';

/// Zero-config LAN discovery.
///
/// The PC broadcasts [DiscoveryPacket.request] to the subnet broadcast address;
/// every phone running DexLink answers with [DiscoveryPacket.encode] carrying
/// its name and TCP port. That removes the manual IP address entry step.
abstract final class DiscoveryPacket {
  /// The fixed datagram a PC broadcasts.
  static Uint8List request() =>
      Uint8List.fromList(utf8.encode('$kDiscoveryMagic DISCOVER'));

  static bool isRequest(Uint8List data) {
    final text = _asText(data);
    return text == '$kDiscoveryMagic DISCOVER';
  }

  /// Builds the phone's answer.
  static Uint8List offer({
    required String deviceName,
    int port = kDefaultTcpPort,
  }) {
    final json = jsonEncode({
      'proto': kDexProtocolVersion,
      'name': deviceName,
      'port': port,
    });
    return Uint8List.fromList(utf8.encode('$kDiscoveryMagic $json'));
  }

  /// Parses an offer, or returns null if [data] is not one.
  static DiscoveryOffer? tryParse(Uint8List data) {
    final text = _asText(data);
    if (!text.startsWith('$kDiscoveryMagic ')) return null;
    final payload = text.substring(kDiscoveryMagic.length + 1);
    if (payload == 'DISCOVER') return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map<String, dynamic>) return null;
      final port = map['port'];
      if (port is! int || port <= 0 || port > 65535) return null;
      return DiscoveryOffer(
        deviceName: (map['name'] as String?) ?? 'Android device',
        port: port,
        protocol: (map['proto'] as int?) ?? kDexProtocolVersion,
      );
    } on FormatException {
      return null;
    }
  }

  static String _asText(Uint8List data) {
    // Ignore trailing NULs some stacks tack on.
    var end = data.length;
    while (end > 0 && data[end - 1] == 0) {
      end--;
    }
    return utf8.decode(
      Uint8List.sublistView(data, 0, end),
      allowMalformed: true,
    );
  }
}

class DiscoveryOffer {
  const DiscoveryOffer({
    required this.deviceName,
    required this.port,
    required this.protocol,
  });

  final String deviceName;
  final int port;
  final int protocol;

  @override
  String toString() => 'DiscoveryOffer($deviceName, port: $port)';
}
