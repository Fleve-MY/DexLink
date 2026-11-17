import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../file_client.dart';

/// Browses and transfers files while the desktop is running.
class FileBrowserDialog extends StatefulWidget {
  const FileBrowserDialog({super.key, required this.host, required this.port});

  final String host;
  final int port;

  @override
  State<FileBrowserDialog> createState() => _FileBrowserDialogState();
}

class _FileBrowserDialogState extends State<FileBrowserDialog> {
  late final PhoneFiles _files = PhoneFiles(
    host: widget.host,
    port: widget.port,
  );
  DirectoryListing? _listing;
  bool _busy = false;
  String? _error;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String path) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final listing = await _files.list(path);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  String get _downloadDirectory {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return p.join(home, 'Downloads', 'DexLink');
  }

  Future<void> _download(FileEntry entry) async {
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    try {
      final target = File(p.join(_downloadDirectory, entry.name));
      await _files.pull(
        path: entry.path,
        destination: target,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress = received / total);
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已下载到 ${target.path}')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
        _progress = null;
      });
    }
  }

  Future<void> _upload() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    try {
      final name = p.basename(file.path);
      final remote = p.posix.join(_listing?.path ?? '', name);
      await _files.push(
        source: File(file.path),
        remotePath: remote,
        onProgress: (sent, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress = sent / total);
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      await _load(_listing?.path ?? '');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final listing = _listing;
    return Dialog(
      backgroundColor: light
          ? theme.colorScheme.surface
          : const Color(0xFF111724),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: light ? const Color(0xFFE1E5EF) : const Color(0xFF23304A),
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 540),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A5F),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.folder_copy_rounded,
                      color: Color(0xFF60A5FA),
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '手机文件管理',
                      style: TextStyle(
                        color: light
                            ? theme.colorScheme.onSurface
                            : Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _upload,
                    icon: const Icon(Icons.upload_file_rounded, size: 17),
                    label: const Text('上传文件到此目录'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: light
                      ? const Color(0xFFEEF0F6)
                      : const Color(0xFF0B0F18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: light
                        ? const Color(0xFFE1E5EF)
                        : const Color(0xFF1D273B),
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回上级目录',
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          listing == null || listing.parent.isEmpty || _busy
                          ? null
                          : () => _load(listing.parent),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        listing?.path ?? '正在读取目录…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: light
                              ? theme.colorScheme.onSurface
                              : const Color(0xFFCBD5E1),
                          fontSize: 12,
                          fontFamily: 'Consolas',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新当前目录',
                      visualDensity: VisualDensity.compact,
                      onPressed: _busy
                          ? null
                          : () => _load(listing?.path ?? ''),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    ),
                  ],
                ),
              ),
              if (_progress != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: _progress),
                ),
              ] else
                const SizedBox(height: 8),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x33EF4444),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x66EF4444)),
                  ),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: light
                          ? const Color(0xFFAE3434)
                          : const Color(0xFFFCA5A5),
                    ),
                  ),
                ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: light
                        ? const Color(0xFFF7F8FC)
                        : const Color(0xFF0D121C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: light
                          ? const Color(0xFFE1E5EF)
                          : const Color(0xFF1C2538),
                    ),
                  ),
                  child: listing == null
                      ? const Center(child: CircularProgressIndicator())
                      : listing.entries.isEmpty
                      ? const Center(
                          child: Text(
                            '此文件夹为空',
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 13,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: listing.entries.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: light
                                ? const Color(0xFFE1E5EF)
                                : const Color(0xFF161F30),
                          ),
                          itemBuilder: (context, index) {
                            final entry = listing.entries[index];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                entry.isDirectory
                                    ? Icons.folder_rounded
                                    : _iconForFile(entry.name),
                                color: entry.isDirectory
                                    ? const Color(0xFFFBBF24)
                                    : const Color(0xFF60A5FA),
                              ),
                              title: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: light
                                      ? theme.colorScheme.onSurface
                                      : const Color(0xFFE2E8F0),
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: entry.isDirectory
                                  ? null
                                  : Text(
                                      _formatSize(entry.size),
                                      style: const TextStyle(
                                        color: Color(0xFF64748B),
                                        fontSize: 11.5,
                                      ),
                                    ),
                              trailing: Icon(
                                entry.isDirectory
                                    ? Icons.chevron_right_rounded
                                    : Icons.download_rounded,
                                size: 18,
                                color: const Color(0xFF94A3B8),
                              ),
                              onTap: _busy
                                  ? null
                                  : () => entry.isDirectory
                                        ? _load(entry.path)
                                        : _download(entry),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconForFile(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov')) {
      return Icons.movie_outlined;
    }
    if (lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.flac')) {
      return Icons.audiotrack_outlined;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.7z') ||
        lower.endsWith('.apk')) {
      return Icons.archive_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
