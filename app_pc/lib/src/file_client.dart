import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One entry of a phone directory.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
    name: '${json['name']}',
    path: '${json['path']}',
    isDirectory: json['dir'] == true,
    size: (json['size'] as num?)?.toInt() ?? 0,
    modified: DateTime.fromMillisecondsSinceEpoch(
      (json['modified'] as num?)?.toInt() ?? 0,
    ),
  );
}

class DirectoryListing {
  const DirectoryListing({
    required this.path,
    required this.parent,
    required this.entries,
  });

  final String path;

  /// Empty when [path] is the root of what the phone is willing to share.
  final String parent;
  final List<FileEntry> entries;

  factory DirectoryListing.fromJson(Map<String, dynamic> json) =>
      DirectoryListing(
        path: '${json['path']}',
        parent: '${json['parent'] ?? ''}',
        entries: ((json['entries'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FileEntry.fromJson)
            .toList(),
      );
}

/// Client for the phone's file channel.
///
/// Every operation opens its own short-lived connection: the channel is
/// low-frequency, and connection-per-request keeps the protocol stateless
/// (no half-open sockets after a failed download).
class PhoneFiles {
  PhoneFiles({required this.host, required this.port});

  final String host;
  final int port;

  static const int _channelFiles = 0x46; // 'F'
  static const int _opList = 1;
  static const int _opPull = 2;
  static const int _opPush = 3;
  static const int _opMkdir = 4;
  static const int _opPaste = 5;
  static const int _opPasteRich = 6;
  static const int _opPasteTarget = 7;
  static const int _opShareAttachments = 8;

  Future<_Framed> _open() async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 6),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.add(<int>[_channelFiles]);
    return _Framed(socket);
  }

  Future<DirectoryListing> list(String path) async {
    final framed = await _open();
    try {
      framed.writeByte(_opList);
      framed.writeString(path);
      await framed.flush();
      final json = await framed.readString();
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('目录列表格式错误');
      }
      return DirectoryListing.fromJson(decoded);
    } finally {
      await framed.close();
    }
  }

  /// Downloads [path] into [destination]; returns the number of bytes written.
  Future<int> pull({
    required String path,
    required File destination,
    void Function(int received, int total)? onProgress,
  }) async {
    final framed = await _open();
    try {
      framed.writeByte(_opPull);
      framed.writeString(path);
      await framed.flush();

      final size = await framed.readInt64();
      if (size < 0) throw FileSystemException('无法读取这个文件', path);

      await destination.parent.create(recursive: true);
      final sink = destination.openWrite();
      try {
        var received = 0;
        while (received < size) {
          final chunk = await framed.readChunk(
            (size - received).clamp(1, 256 * 1024),
          );
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, size);
        }
        await sink.flush();
        return received;
      } finally {
        await sink.close();
      }
    } finally {
      await framed.close();
    }
  }

  Future<void> push({
    required File source,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) async => _push(
    chunks: source.openRead(),
    size: await source.length(),
    remotePath: remotePath,
    onProgress: onProgress,
  );

  /// Upload encoded clipboard images directly, without a local temporary file.
  Future<void> pushBytes({
    required Uint8List bytes,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) => _push(
    chunks: Stream<List<int>>.value(bytes),
    size: bytes.length,
    remotePath: remotePath,
    onProgress: onProgress,
  );

  Future<void> _push({
    required Stream<List<int>> chunks,
    required int size,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) async {
    final framed = await _open();
    try {
      framed.writeByte(_opPush);
      framed.writeString(remotePath);
      framed.writeInt64(size);
      await framed.flush();

      var sent = 0;
      await for (final chunk in chunks) {
        framed.writeBytes(chunk);
        await framed.flush();
        sent += chunk.length;
        onProgress?.call(sent, size);
      }
      final ok = await framed.readBool();
      if (!ok) throw FileSystemException('手机端拒绝写入', remotePath);
    } finally {
      await framed.close();
    }
  }

  Future<bool> mkdir(String path) async {
    final framed = await _open();
    try {
      framed.writeByte(_opMkdir);
      framed.writeString(path);
      await framed.flush();
      return await framed.readBool();
    } finally {
      await framed.close();
    }
  }

  /// Puts an already-uploaded file on the phone's clipboard.
  ///
  /// Legacy clipboard-only operation. New callers should use [pasteAttachments]
  /// to distinguish a submitted attachment from clipboard preparation.
  Future<String> paste(String path) async {
    final framed = await _open();
    try {
      framed.writeByte(_opPaste);
      framed.writeString(path);
      await framed.flush();
      return await framed.readString();
    } finally {
      await framed.close();
    }
  }

  /// Snapshot the active editor before uploading, so a delayed transfer cannot
  /// insert into a different input field.
  Future<Map<String, dynamic>> pasteTarget() async {
    final framed = await _open();
    try {
      framed.writeByte(_opPasteTarget);
      await framed.flush();
      final result = jsonDecode(await framed.readString());
      if (result is! Map<String, dynamic>) {
        throw const FormatException('输入框状态无效');
      }
      return result;
    } finally {
      await framed.close();
    }
  }

  Future<AttachmentPasteResult> pasteAttachments(
    List<String> paths, {
    required Map<String, dynamic> target,
  }) async {
    if (paths.isEmpty || paths.length > 32) {
      throw ArgumentError('一次请选择 1～32 个文件');
    }
    final framed = await _open();
    try {
      framed.writeByte(_opPasteRich);
      framed.writeString(
        jsonEncode({
          'token': target['token'] ?? '',
          'package': target['package'] ?? '',
          'display': target['display'] ?? -1,
          'paths': paths,
        }),
      );
      await framed.flush();
      final result = AttachmentPasteResult.fromJson(
        jsonDecode(await framed.readString()),
      );
      if (result.total != paths.length) {
        throw const FormatException('附件数量回执不一致');
      }
      return result;
    } finally {
      await framed.close();
    }
  }

  /// Prepare a phone notification; only the user's tap opens the share sheet.
  Future<String> shareAttachments(List<String> paths) async {
    if (paths.isEmpty || paths.length > 32) {
      throw ArgumentError('一次请选择 1～32 个文件');
    }
    final framed = await _open();
    try {
      framed.writeByte(_opShareAttachments);
      framed.writeString(jsonEncode({'paths': paths}));
      await framed.flush();
      final result = jsonDecode(await framed.readString());
      if (result is! Map<String, dynamic> ||
          !{
            'shareReady',
            'notificationsDisabled',
            'failed',
          }.contains(result['status']) ||
          result['message'] is! String) {
        throw const FormatException('附件分享结果无效');
      }
      return result['message'] as String;
    } finally {
      await framed.close();
    }
  }
}

class AttachmentPasteResult {
  const AttachmentPasteResult(
    this.status,
    this.accepted,
    this.total,
    this.clipboardReady,
    this.message,
  );
  final String status, message;
  final int accepted, total;
  final bool clipboardReady;

  factory AttachmentPasteResult.fromJson(dynamic value) {
    if (value is! Map<String, dynamic>) throw const FormatException('附件粘贴结果无效');
    final status = value['status'];
    final accepted = value['accepted'];
    final total = value['total'];
    final message = value['message'];
    if (status is! String ||
        accepted is! int ||
        total is! int ||
        total < 1 ||
        total > 32 ||
        accepted < 0 ||
        accepted > total ||
        message is! String ||
        !{
          'accepted',
          'partial',
          'rejected',
          'unsupported',
          'needsInputMethod',
          'focusChanged',
          'failed',
        }.contains(status) ||
        (status == 'accepted' && accepted != total) ||
        (status != 'accepted' && status != 'partial' && accepted != 0) ||
        (status == 'partial' && (accepted == 0 || accepted == total))) {
      throw const FormatException('附件粘贴结果无效');
    }
    return AttachmentPasteResult(
      status,
      accepted,
      total,
      value['clipboardReady'] == true,
      message,
    );
  }
}

/// Big-endian framing helpers over a socket, matching `BridgeService.kt`.
class _Framed {
  _Framed(this._socket) {
    _subscription = _socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _waiter?.complete();
        _waiter = null;
      },
      onDone: () {
        _closed = true;
        _waiter?.completeError(const SocketException('文件通道已断开'));
        _waiter = null;
      },
      onError: (Object error) {
        _error = error;
        _waiter?.completeError(error);
        _waiter = null;
      },
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = <int>[];
  Completer<void>? _waiter;
  bool _closed = false;
  Object? _error;

  void writeByte(int value) => _socket.add(<int>[value & 0xFF]);

  void writeBytes(List<int> bytes) => _socket.add(bytes);

  void writeInt64(int value) {
    final data = ByteData(8)..setInt64(0, value, Endian.big);
    _socket.add(data.buffer.asUint8List());
  }

  void writeString(String value) {
    final bytes = utf8.encode(value);
    final header = ByteData(4)..setInt32(0, bytes.length, Endian.big);
    _socket.add(header.buffer.asUint8List());
    _socket.add(bytes);
  }

  Future<void> flush() => _socket.flush();

  Future<void> _ensure(int count) async {
    while (_buffer.length < count) {
      if (_error != null) throw _error!;
      if (_closed) throw const SocketException('文件通道已断开');
      _waiter ??= Completer<void>();
      await _waiter!.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () =>
            throw const SocketException('手机文件通道长时间未响应，请重新打开手机端 DexLink'),
      );
    }
  }

  Future<Uint8List> readChunk(int max) async {
    await _ensure(1);
    final take = _buffer.length < max ? _buffer.length : max;
    final out = Uint8List.fromList(_buffer.sublist(0, take));
    _buffer.removeRange(0, take);
    return out;
  }

  Future<Uint8List> readBytes(int count) async {
    await _ensure(count);
    final out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return out;
  }

  Future<int> readInt64() async {
    final bytes = await readBytes(8);
    return ByteData.sublistView(bytes).getInt64(0, Endian.big);
  }

  Future<int> readInt32() async {
    final bytes = await readBytes(4);
    return ByteData.sublistView(bytes).getInt32(0, Endian.big);
  }

  Future<String> readString() async {
    final length = await readInt32();
    if (length < 0 || length > 1 << 20) {
      throw const FormatException('字符串长度非法');
    }
    return utf8.decode(await readBytes(length), allowMalformed: true);
  }

  Future<bool> readBool() async => (await readBytes(1)).first != 0;

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
    _socket.destroy();
  }
}
