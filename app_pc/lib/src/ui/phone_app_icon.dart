import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Decode catalog bytes only when the icon changes, not on every task poll.
class PhoneAppIcon extends StatefulWidget {
  const PhoneAppIcon({super.key, this.encoded, this.size = 40});
  final String? encoded;
  final double size;
  @override
  State<PhoneAppIcon> createState() => _PhoneAppIconState();
}

class _PhoneAppIconState extends State<PhoneAppIcon> {
  Uint8List? bytes;
  void decode() {
    try {
      bytes = widget.encoded == null ? null : base64Decode(widget.encoded!);
    } catch (_) {
      bytes = null;
    }
  }

  @override
  void initState() {
    super.initState();
    decode();
  }

  @override
  void didUpdateWidget(PhoneAppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.encoded != widget.encoded) decode();
  }

  @override
  Widget build(BuildContext context) => bytes == null
      ? Icon(
          Icons.apps_rounded,
          size: widget.size,
          color: const Color(0xFFAEBACA),
        )
      : Image.memory(
          bytes!,
          width: widget.size,
          height: widget.size,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => Icon(
            Icons.apps_rounded,
            size: widget.size,
            color: const Color(0xFFAEBACA),
          ),
        );
}
