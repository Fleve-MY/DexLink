# Third-party components

DexLink source code uses the Apache License 2.0. Dependencies and separately distributed tools retain their own licenses.

| Component | Use | License / upstream |
| --- | --- | --- |
| Flutter and Dart | Application UI and shared protocol | [Flutter BSD-3-Clause](https://github.com/flutter/flutter/blob/master/LICENSE), [Dart BSD-3-Clause](https://github.com/dart-lang/sdk/blob/main/LICENSE) |
| Shizuku API / provider | Android shell process access | [Apache-2.0](https://github.com/RikkaApps/Shizuku-API/blob/master/LICENSE) |
| Shizuku manager | Optional, unchanged APK in Windows offline setup | [Apache-2.0](third_party/android/Shizuku-LICENSE.txt) |
| Nightzuku manager | Optional, unchanged APK in Windows offline setup | [Apache-2.0](third_party/android/Nightzuku-LICENSE.txt) |
| Android Debug Bridge | USB application installation | Copyright and component license notices in `support/adb/NOTICE.txt` in the Windows package |
| Dart and Flutter packages | File selection, FFI, paths and cryptography | Exact versions in each application's `pubspec.lock`. Bundled Flutter license notices are in `data/flutter_assets/NOTICES.Z` |
| FFmpeg | Optional external compatibility decoder | [License depends on the selected build](https://ffmpeg.org/legal.html). FFmpeg is not included in the release package |

The Windows offline setup payload includes the unmodified Shizuku and Nightzuku APKs, their license texts, ADB notices, and a manifest with exact versions and SHA-256 hashes. See [offline component notices](third_party/android/THIRD_PARTY_NOTICES.md).

Android and Windows system APIs remain subject to their respective platform terms. The application icons shown for installed phone apps belong to their respective owners.
