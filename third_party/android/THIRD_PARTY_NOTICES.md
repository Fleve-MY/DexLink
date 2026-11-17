# Offline Android setup components

DexLink distributes the following optional Android managers unchanged. They are
independent applications, not DexLink's capture implementation.

- Shizuku 13.6.0.r1086.2650830c by RikkaApps and contributors.
  Source: https://github.com/RikkaApps/Shizuku/tree/2650830c
  License: Apache License 2.0, see licenses/Shizuku-LICENSE.txt in the PC bundle.
- Nightzuku 13.7.1.r60.4109165 by kerneldroid and contributors, based on Shizuku.
  Source: https://github.com/kerneldroid/Nightzuku/tree/4109165
  License: Apache License 2.0, see licenses/Nightzuku-LICENSE.txt in the PC bundle.
- Android Debug Bridge (ADB), from Android SDK Platform-Tools 37.0.1.
  Source: https://android.googlesource.com/platform/packages/modules/adb/
  Copyright and license notices are retained in adb/NOTICE.txt.

The setup manifest records exact APK versions and SHA-256 digests. Download APKs
from the upstream release pages; the preparation script verifies their package IDs
and signing certificate digests before bundling. Android 17 uses the project's
Shizuku + Nightzuku setup profile. This is a recommendation for these bundled
versions, not a claim that a target SDK value establishes a hard OS support limit.

Installing a manager does not start its service or grant DexLink access. The user
must start the desired manager and approve DexLink on the phone.
