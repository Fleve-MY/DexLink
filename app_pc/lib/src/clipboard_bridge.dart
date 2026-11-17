import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// What the Windows clipboard currently holds, in the order we care about.
sealed class ClipboardPayload {
  const ClipboardPayload();
}

/// One or more files copied in Explorer.
class ClipboardFiles extends ClipboardPayload {
  const ClipboardFiles(this.paths);
  final List<String> paths;
}

/// A bitmap copied from a screenshot tool or a browser, as encoded bytes.
class ClipboardImage extends ClipboardPayload {
  const ClipboardImage(this.bytes, this.extension);
  final Uint8List bytes;

  /// `png` or `bmp` — whatever the clipboard actually carried.
  final String extension;
}

/// Plain text.
class ClipboardPlainText extends ClipboardPayload {
  const ClipboardPlainText(this.text);
  final String text;
}

/// Reads the Windows clipboard without going through Flutter.
///
/// `Clipboard.getData` only exposes plain text, but "copy an image, paste it on
/// the phone" is the whole point here: images arrive as `PNG` (screenshot
/// tools, browsers) or `CF_DIB` (PrintScreen), and files as `CF_HDROP`.
abstract final class WindowsClipboard {
  static final bool _supported = !Platform.isWindows ? false : _load();

  static DynamicLibrary? _user32;
  static DynamicLibrary? _kernel32;
  static DynamicLibrary? _shell32;

  static late final int Function(Pointer<Void>) _openClipboard;
  static late final int Function() _closeClipboard;
  static late final int Function(int) _isFormatAvailable;
  static late final Pointer<Void> Function(int) _getClipboardData;
  static late final int Function(Pointer<Utf16>) _registerFormat;
  static late final int Function(Pointer<Void>, int, Pointer<Utf16>, int)
      _dragQueryFile;
  static late final Pointer<Void> Function(Pointer<Void>) _globalLock;
  static late final int Function(Pointer<Void>) _globalUnlock;
  static late final int Function(Pointer<Void>) _globalSize;

  static bool _load() {
    try {
      _user32 = DynamicLibrary.open('user32.dll');
      _kernel32 = DynamicLibrary.open('kernel32.dll');
      // DragQueryFileW is a shell function, not a user32 one; looking it up in
      // user32 throws and used to disable the whole bridge without a word.
      _shell32 = DynamicLibrary.open('shell32.dll');

      _openClipboard = _user32!
          .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'OpenClipboard',
      );
      _closeClipboard =
          _user32!.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
      _isFormatAvailable = _user32!.lookupFunction<
          Int32 Function(Uint32),
          int Function(int)>('IsClipboardFormatAvailable');
      _getClipboardData = _user32!.lookupFunction<
          Pointer<Void> Function(Uint32),
          Pointer<Void> Function(int)>('GetClipboardData');
      _registerFormat = _user32!.lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)>('RegisterClipboardFormatW');
      _dragQueryFile = _shell32!.lookupFunction<
          Uint32 Function(Pointer<Void>, Uint32, Pointer<Utf16>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Utf16>, int)>(
        'DragQueryFileW',
      );
      _globalLock = _kernel32!.lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('GlobalLock');
      _globalUnlock = _kernel32!.lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('GlobalUnlock');
      _globalSize = _kernel32!.lookupFunction<
          UintPtr Function(Pointer<Void>),
          int Function(Pointer<Void>)>('GlobalSize');
      return true;
    } catch (error) {
      // A failed lookup here means Ctrl+V silently does nothing, so the reason
      // has to survive for the debug overlay.
      loadError = '$error';
      return false;
    }
  }

  static bool get isSupported => _supported;

  /// Why [isSupported] is false, when it is.
  static String? loadError;

  /// Files first, then images, then text — the order users expect.
  static ClipboardPayload? read() {
    if (!_supported) return null;
    final files = _files();
    if (files.isNotEmpty) return ClipboardFiles(files);

    final image = _image();
    if (image != null) return image;

    return null;
  }

  /// Another process (a clipboard manager, or the app that just copied) holds
  /// the clipboard for a few milliseconds, and OpenClipboard simply fails.
  static bool _open() {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (_openClipboard(nullptr) != 0) return true;
      sleep(const Duration(milliseconds: 20));
    }
    return false;
  }

  static List<String> _files() {
    if (!_open()) return const [];
    try {
      // CF_HDROP
      if (_isFormatAvailable(15) == 0) return const [];
      final handle = _getClipboardData(15);
      if (handle == nullptr) return const [];
      final count = _dragQueryFile(handle, 0xFFFFFFFF, nullptr, 0);
      final paths = <String>[];
      for (var index = 0; index < count; index++) {
        final length = _dragQueryFile(handle, index, nullptr, 0);
        if (length <= 0) continue;
        final buffer = calloc<Uint16>(length + 1);
        try {
          _dragQueryFile(handle, index, buffer.cast<Utf16>(), length + 1);
          final path = buffer.cast<Utf16>().toDartString();
          if (path.isNotEmpty) paths.add(path);
        } finally {
          calloc.free(buffer);
        }
      }
      return paths;
    } finally {
      _closeClipboard();
    }
  }

  static ClipboardImage? _image() {
    if (!_open()) return null;
    try {
      // "PNG" is a registered format most modern Windows apps publish.
      final pngName = 'PNG'.toNativeUtf16();
      final pngFormat = _registerFormat(pngName);
      calloc.free(pngName);
      if (pngFormat != 0 && _isFormatAvailable(pngFormat) != 0) {
        final bytes = _bytesOf(pngFormat);
        if (bytes != null && bytes.length > 8) {
          return ClipboardImage(bytes, 'png');
        }
      }
      // PrintScreen and older tools only publish CF_DIB (8). Wrap it into a
      // real .bmp file so both the phone and ffmpeg can read it.
      if (_isFormatAvailable(8) != 0) {
        final dib = _bytesOf(8);
        if (dib != null) {
          final bmp = _dibToBmp(dib);
          if (bmp != null) return ClipboardImage(bmp, 'bmp');
        }
      }
      return null;
    } finally {
      _closeClipboard();
    }
  }

  /// Copies the payload of a clipboard format into Dart-owned memory.
  static Uint8List? _bytesOf(int format) {
    final handle = _getClipboardData(format);
    if (handle == nullptr) return null;
    final size = _globalSize(handle);
    if (size <= 0 || size > 512 * 1024 * 1024) return null;
    final pointer = _globalLock(handle);
    if (pointer == nullptr) return null;
    try {
      return Uint8List.fromList(pointer.cast<Uint8>().asTypedList(size));
    } finally {
      _globalUnlock(handle);
    }
  }

  /// A DIB is a BMP without the 14-byte file header. The palette size depends
  /// on the header, so it has to be read out of the DIB itself.
  static Uint8List? _dibToBmp(Uint8List dib) {
    if (dib.length < 40) return null;
    final header = ByteData.sublistView(dib);
    final headerSize = header.getUint32(0, Endian.little);
    if (headerSize < 12 || headerSize > dib.length) return null;
    final bitCount = header.getUint16(14, Endian.little);
    final coloursUsed = header.getUint32(32, Endian.little);
    var palette = 0;
    if (bitCount <= 8) {
      palette = (coloursUsed == 0 ? 1 << bitCount : coloursUsed) * 4;
    }
    final dataOffset = 14 + headerSize + palette;
    // The file is exactly the header we synthesise plus the DIB we were given;
    // claiming a bigger size makes strict decoders read past the end.
    final fileSize = 14 + dib.length;
    final out = Uint8List(fileSize);
    out[0] = 0x42; // 'B'
    out[1] = 0x4D; // 'M'
    final view = ByteData.sublistView(out);
    view.setUint32(2, fileSize, Endian.little);
    view.setUint32(10, dataOffset, Endian.little);
    out.setRange(14, 14 + dib.length, dib);
    return out;
  }
}
