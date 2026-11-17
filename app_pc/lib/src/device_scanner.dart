import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dex_link/dex_link.dart';

import 'discovery_client.dart';

class FoundDevice {
  const FoundDevice({
    required this.name,
    required this.host,
    required this.port,
  });

  final String name;
  final String host;
  final int port;

  String get id => '$host:$port';

  @override
  String toString() => '$name ($host:$port)';
}

/// Finds phones on the local network without the user typing an address.
///
/// Two strategies run in parallel because either can fail on its own:
///
///  * a UDP broadcast, which is instant but silently dropped when Windows
///    Firewall blocks the reply;
///  * a TCP sweep of the local /24s, where the PC is the one connecting out, so
///    it works even with the firewall on.
class DeviceScanner {
  static const int _probeChannel = 0x50; // 'P'
  static const int _probeConcurrency = 96;
  static const int _maxHosts = 1800;

  /// Interface names that are never where the phone lives; sweeping them just
  /// wastes the whole budget on VPNs and virtual adapters.
  static const List<String> _skipPrefixes = [
    'vethernet',
    'vmware',
    'virtualbox',
    'vbox',
    'tailscale',
    'zerotier',
    'wintun',
    'tap',
    'tun',
    'npcap',
    'loopback',
    'bluetooth',
  ];

  static Future<List<FoundDevice>> scan({
    int port = kDefaultTcpPort,
    String? extraHost,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final found = <String, FoundDevice>{};
    void merge(List<FoundDevice> devices) {
      for (final device in devices) {
        found[device.id] = device;
      }
    }

    try {
      await Future.wait<void>([
        _broadcast(port).then(merge).catchError((_) {}),
        _probeSubnets(port, extraHost).then(merge).catchError((_) {}),
      ]).timeout(timeout);
    } on TimeoutException {
      // Keep whatever answered in time; the sweep continues in the background.
    }

    final devices = found.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return devices;
  }

  static Future<List<FoundDevice>> _broadcast(int port) async {
    final devices =
        await LanDiscovery.search(timeout: const Duration(seconds: 2));
    return [
      for (final device in devices)
        FoundDevice(name: device.name, host: device.ip, port: device.port),
    ];
  }

  static Future<List<FoundDevice>> _probeSubnets(
    int port,
    String? extraHost,
  ) async {
    final hosts = (await _candidateHosts(extraHost)).toList();
    final results = <FoundDevice>[];
    for (var index = 0; index < hosts.length; index += _probeConcurrency) {
      final end = (index + _probeConcurrency).clamp(0, hosts.length);
      final batch = await Future.wait(
        hosts.sublist(index, end).map((host) => _probe(host, port)),
      );
      results.addAll(batch.whereType<FoundDevice>());
    }
    return results;
  }

  static Future<Set<String>> _candidateHosts(String? extraHost) async {
    final hosts = <String>{};
    if (extraHost != null && extraHost.isNotEmpty) {
      hosts.add(extraHost);
    }
    try {
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      )) {
        final name = interface.name.toLowerCase();
        if (_skipPrefixes.any(name.startsWith)) continue;
        for (final address in interface.addresses) {
          final parts = address.address.split('.');
          if (parts.length != 4) continue;
          final prefix = parts.sublist(0, 3).join('.');
          for (var host = 1; host <= 254; host++) {
            final candidate = '$prefix.$host';
            if (candidate != address.address) hosts.add(candidate);
          }
        }
      }
    } catch (_) {
      // Fall through to the USB range below.
    }
    // Android USB tethering hands out 192.168.42.x on virtually every device.
    for (var host = 1; host <= 254; host++) {
      hosts.add('192.168.42.$host');
    }
    if (hosts.length > _maxHosts) {
      return hosts.take(_maxHosts).toSet();
    }
    return hosts;
  }

  static Future<FoundDevice?> _probe(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 220),
      );
      socket.add(<int>[_probeChannel]);
      final bytes = await _readAll(socket);
      if (bytes.isEmpty) return null;
      final offer = DiscoveryPacket.tryParse(Uint8List.fromList(bytes));
      if (offer == null) return null;
      return FoundDevice(name: offer.deviceName, host: host, port: port);
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  static Future<List<int>> _readAll(
    Socket socket, {
    Duration timeout = const Duration(milliseconds: 700),
  }) async {
    final buffer = <int>[];
    final done = Completer<void>();
    final subscription = socket.listen(
      buffer.addAll,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await done.future.timeout(timeout);
    } catch (_) {
      // A partial reply is still worth parsing.
    }
    await subscription.cancel();
    return buffer;
  }
}
