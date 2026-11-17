import 'dart:async';
import 'dart:io';

import 'package:dex_link/dex_link.dart';

/// A phone found on the local network.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.name,
    required this.ip,
    required this.port,
  });

  final String name;
  final String ip;
  final int port;

  @override
  String toString() => '$name ($ip:$port)';
}

/// Broadcasts a discovery datagram and collects the phones that answer.
///
/// This is what removes the "type the IP address" step; on a normal home
/// network it finds the phone in well under a second.
class LanDiscovery {
  static Future<List<DiscoveredDevice>> search({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    final found = <String, DiscoveredDevice>{};
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final offer = DiscoveryPacket.tryParse(datagram.data);
      if (offer == null) return;
      final ip = datagram.address.address;
      found['$ip:${offer.port}'] = DiscoveredDevice(
        name: offer.deviceName,
        ip: ip,
        port: offer.port,
      );
    });

    final request = DiscoveryPacket.request();
    void broadcast() {
      try {
        socket.send(request, InternetAddress('255.255.255.255'), kDiscoveryPort);
      } catch (_) {
        // Interfaces without broadcast support are simply skipped.
      }
    }

    broadcast();
    final retry = Timer.periodic(const Duration(milliseconds: 400), (_) => broadcast());
    await Future<void>.delayed(timeout);
    retry.cancel();
    await subscription.cancel();
    socket.close();
    return found.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
}
