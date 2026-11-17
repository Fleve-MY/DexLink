import 'dart:typed_data';

/// Minimal MPEG-TS muxer for H.264.
///
/// Why not send the bare Annex-B stream? Because the libmpv that media_kit ships
/// has no raw-H.264 demuxer (`lavf: Unknown lavf format h264`), and there is no
/// way to hand it a format hint that works. A transport stream, on the other
/// hand, is detected from its 0x47 sync byte, so no option is needed at all.
///
/// Only what a decoder needs is produced: PAT, PMT with one H.264 elementary
/// stream, a PCR packet per access unit, and PES packets with PTS.
class TsMuxer {
  bool hevc = false;
  static const int _packetSize = 188;
  static const int _pmtPid = 0x1000;
  static const int _videoPid = 0x0100;

  static final Uint8List _aud = Uint8List.fromList(const <int>[
    0x00,
    0x00,
    0x00,
    0x01,
    0x09,
    0xF0,
  ]);
  static final _hevcAud = Uint8List.fromList([0, 0, 0, 1, 0x46, 1, 0x50]);

  int _ccPat = 0;
  int _ccPmt = 0;
  int _ccVideo = 0;
  int _accessUnits = 0;

  /// Forgets everything about the previous stream.
  ///
  /// A reconnect is a new encoder: the continuity counters restart at zero in
  /// its own TS (in practice ffmpeg re-syncs, but a decoder that is still fed
  /// the old counters can emit "continuity check failed" for a while), and the
  /// PAT/PMT must be re-sent before the first frame of the new stream.
  void reset() {
    _ccPat = 0;
    _ccPmt = 0;
    _ccVideo = 0;
    _accessUnits = 0;
  }

  /// PAT + PMT. Sent before the first frame and then periodically, so a decoder
  /// that joins late still learns the program layout.
  Uint8List tables() {
    final out = BytesBuilder(copy: true);
    out.add(
      _psiPacket(0x0000, _next((_) => _ccPat, (v) => _ccPat = v), _pat()),
    );
    out.add(
      _psiPacket(_pmtPid, _next((_) => _ccPmt, (v) => _ccPmt = v), _pmt()),
    );
    return out.takeBytes();
  }

  /// Wraps one encoded access unit (Annex-B, with start codes) into TS packets.
  ///
  /// When [configPrefix] (SPS/PPS) is provided (e.g. for an IDR keyframe), it
  /// is placed inside the same PES access unit before the slice data so the
  /// decoder always receives matching parameter sets with the frame's own PTS
  /// and continuity counter. A trailing H.264 Access Unit Delimiter (AUD) is
  /// appended so FFmpeg's H.264 parser flushes the frame immediately without
  /// waiting for the next frame to arrive from the phone.
  Uint8List accessUnit(
    Uint8List data,
    int ptsMicros, {
    Uint8List? configPrefix,
  }) {
    final stripped = _stripLeadingAud(data);
    if (stripped.isEmpty && (configPrefix == null || configPrefix.isEmpty)) {
      return Uint8List(0);
    }
    _accessUnits++;
    final out = BytesBuilder(copy: true);
    if (_accessUnits == 1 || _accessUnits % 30 == 0 || configPrefix != null) {
      out.add(tables());
    }

    final framed = BytesBuilder(copy: false);
    if (_accessUnits == 1) {
      framed.add(hevc ? _hevcAud : _aud);
    }
    if (configPrefix != null && configPrefix.isNotEmpty) {
      framed.add(_stripLeadingAud(configPrefix));
    }
    framed.add(stripped);

    final pts = _to90k(ptsMicros);
    out.add(_pcrPacket(pts));
    out.add(_pesChain(framed.toBytes(), pts));
    // A separate PES holding only an AUD makes the demuxer emit the frame's
    // PES right away and lets the H.264 parser close the access unit without
    // waiting for the next frame. The parser starts the *next* access unit at
    // this AUD and takes its timestamp from this PES, so it must carry a real,
    // strictly increasing PTS (half a 60 fps frame after this one).
    out.add(_pesPackets(_pes(hevc ? _hevcAud : _aud, pts + 750)));
    return out.takeBytes();
  }

  Uint8List _stripLeadingAud(Uint8List data) {
    if (hevc) {
      final code =
          data.length >= 7 &&
              data[0] == 0 &&
              data[1] == 0 &&
              data[2] == 0 &&
              data[3] == 1
          ? 4
          : data.length >= 6 && data[0] == 0 && data[1] == 0 && data[2] == 1
          ? 3
          : 0;
      return code != 0 && (data[code] >> 1) & 63 == 35
          ? Uint8List.sublistView(data, code + 3)
          : data;
    }
    if (data.length >= 6 &&
        data[0] == 0x00 &&
        data[1] == 0x00 &&
        data[2] == 0x00 &&
        data[3] == 0x01 &&
        (data[4] & 0x1F) == 9) {
      return Uint8List.sublistView(data, 6);
    }
    if (data.length >= 5 &&
        data[0] == 0x00 &&
        data[1] == 0x00 &&
        data[2] == 0x01 &&
        (data[3] & 0x1F) == 9) {
      return Uint8List.sublistView(data, 5);
    }
    return data;
  }

  // ------------------------------------------------------------------ pieces

  int _next(int Function(int) read, void Function(int) write) {
    final value = read(0);
    write((value + 1) & 0x0F);
    return value;
  }

  Uint8List _pat() {
    final section = <int>[
      0x00, // table_id: program association
      0x00, 0x00, // section_length placeholder
      0x00, 0x01, // transport_stream_id
      0xC1, // version 0, current_next 1
      0x00, // section_number
      0x00, // last_section_number
      0x00, 0x01, // program_number
      0xE0 | ((_pmtPid >> 8) & 0x1F), _pmtPid & 0xFF,
    ];
    return _finishSection(section);
  }

  Uint8List _pmt() {
    final section = <int>[
      0x02, // table_id: program map
      0x00, 0x00, // section_length placeholder
      0x00, 0x01, // program_number
      0xC1, // version 0, current_next 1
      0x00,
      0x00,
      0xE0 | ((_videoPid >> 8) & 0x1F), _videoPid & 0xFF, // PCR_PID
      0xF0, 0x00, // program_info_length
      hevc ? 0x24 : 0x1B, // HEVC or AVC elementary stream.
      0xE0 | ((_videoPid >> 8) & 0x1F), _videoPid & 0xFF,
      0xF0, 0x00, // ES_info_length
    ];
    return _finishSection(section);
  }

  /// Fills in `section_length` and appends the CRC32.
  Uint8List _finishSection(List<int> section) {
    final length = section.length - 3 + 4;
    section[1] = 0xB0 | ((length >> 8) & 0x0F);
    section[2] = length & 0xFF;
    final crc = _crc32(section);
    section.addAll([
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ]);
    return Uint8List.fromList(section);
  }

  Uint8List _psiPacket(int pid, int continuity, Uint8List section) {
    final packet = Uint8List(_packetSize)..fillRange(0, _packetSize, 0xFF);
    packet[0] = 0x47;
    packet[1] = 0x40 | ((pid >> 8) & 0x1F); // payload_unit_start_indicator
    packet[2] = pid & 0xFF;
    packet[3] = 0x10 | (continuity & 0x0F);
    packet[4] = 0x00; // pointer_field
    packet.setRange(5, 5 + section.length, section);
    return packet;
  }

  Uint8List _pcrPacket(int pts) {
    final packet = Uint8List(_packetSize)..fillRange(0, _packetSize, 0xFF);
    packet[0] = 0x47;
    packet[1] = (_videoPid >> 8) & 0x1F;
    packet[2] = _videoPid & 0xFF;
    // Adaptation field only. The continuity counter must NOT advance here: only
    // packets that carry payload bump it, otherwise the demuxer sees a gap on
    // every frame and throws the packet away ("continuity check failed").
    packet[3] = 0x20 | (_ccVideo & 0x0F);
    packet[4] = 183; // adaptation_field_length
    packet[5] = 0x10; // PCR flag
    packet[6] = (pts >> 25) & 0xFF;
    packet[7] = (pts >> 17) & 0xFF;
    packet[8] = (pts >> 9) & 0xFF;
    packet[9] = (pts >> 1) & 0xFF;
    packet[10] = ((pts & 0x01) << 7) | 0x7E;
    packet[11] = 0x00;
    return packet;
  }

  /// Splits one access unit into PES packets small enough for the 16 bit
  /// `PES_packet_length` field and packetises them.
  ///
  /// A 1080p keyframe is routinely 60–300 KB, far above the 65535 byte limit.
  /// Writing an overflowing length (or 0, "until the next PES") makes ffmpeg
  /// log `Packet corrupt` and drop the tail of the frame — which on a live
  /// stream looks like a frozen or black window. Only the first PES carries the
  /// PTS; the continuations have no optional header, which the spec allows and
  /// keeps the access unit in one piece for the H.264 parser.
  Uint8List _pesChain(Uint8List payload, int pts) {
    const maxLength = 0xFFFF;
    final out = BytesBuilder(copy: true);
    var offset = 0;
    var first = true;
    while (offset < payload.length) {
      final overhead = first ? 8 : 3; // PES header after the length field
      final chunk = (payload.length - offset).clamp(0, maxLength - overhead);
      final slice = Uint8List.sublistView(payload, offset, offset + chunk);
      out.add(_pesPackets(_pes(slice, first ? pts : -1)));
      offset += chunk;
      first = false;
    }
    return out.takeBytes();
  }

  Uint8List _pes(Uint8List payload, int pts) {
    final hasPts = pts >= 0;
    final prefixLength = 6;
    // 3 common bytes (flags + header length) + 5 PTS bytes when present.
    final optHeaderLength = hasPts ? 8 : 3;
    final total = prefixLength + optHeaderLength + payload.length;
    final bodyLength = total - prefixLength;
    final pes = Uint8List(total);
    pes[0] = 0x00;
    pes[1] = 0x00;
    pes[2] = 0x01;
    pes[3] = 0xE0; // video stream
    pes[4] = (bodyLength >> 8) & 0xFF;
    pes[5] = bodyLength & 0xFF;
    pes[6] = 0x80; // '10' marker
    pes[7] = hasPts ? 0x80 : 0x00; // PTS present?
    pes[8] = hasPts ? 0x05 : 0x00; // PES header data length
    var headerEnd = 9;
    if (hasPts) {
      pes[9] = 0x21 | (((pts >> 30) & 0x07) << 1);
      pes[10] = (pts >> 22) & 0xFF;
      pes[11] = 0x01 | (((pts >> 15) & 0x7F) << 1);
      pes[12] = (pts >> 7) & 0xFF;
      pes[13] = 0x01 | ((pts & 0x7F) << 1);
      headerEnd = 14;
    }
    pes.setRange(headerEnd, headerEnd + payload.length, payload);
    return pes;
  }

  Uint8List _pesPackets(Uint8List pes) {
    final out = BytesBuilder(copy: true);
    var offset = 0;
    var first = true;
    while (offset < pes.length) {
      final packet = Uint8List(_packetSize);
      packet[0] = 0x47;
      packet[1] = (first ? 0x40 : 0x00) | ((_videoPid >> 8) & 0x1F);
      packet[2] = _videoPid & 0xFF;
      final remaining = pes.length - offset;
      if (remaining >= 184) {
        packet[3] = 0x10 | (_ccVideo & 0x0F);
        _ccVideo = (_ccVideo + 1) & 0x0F;
        packet.setRange(4, 188, pes, offset);
        offset += 184;
      } else {
        // Last packet of the PES: pad with an adaptation field instead of
        // trailing zero bytes, which the decoder would parse as payload.
        packet.fillRange(0, _packetSize, 0xFF);
        packet
          ..[0] = 0x47
          ..[1] = (first ? 0x40 : 0x00) | ((_videoPid >> 8) & 0x1F)
          ..[2] = _videoPid & 0xFF
          ..[3] = 0x30 | (_ccVideo & 0x0F); // adaptation field + payload
        _ccVideo = (_ccVideo + 1) & 0x0F;
        final adaptationLength = 183 - remaining;
        packet[4] = adaptationLength;
        if (adaptationLength > 0) {
          packet[5] = 0x00; // flags: nothing but stuffing follows
        }
        packet.setRange(5 + adaptationLength, 188, pes, offset);
        offset = pes.length;
      }
      first = false;
      out.add(packet);
    }
    return out.takeBytes();
  }

  static int _to90k(int micros) {
    if (micros <= 0) return 0;
    return ((micros * 9) ~/ 100) & 0x1FFFFFFFF;
  }

  static int _crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= (byte << 24) & 0xFFFFFFFF;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x80000000) != 0
            ? ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            : (crc << 1) & 0xFFFFFFFF;
      }
    }
    return crc;
  }
}
