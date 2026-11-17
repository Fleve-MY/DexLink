import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'src/session_log.dart';
import 'src/ui/connect_page.dart';
import 'src/theme_settings.dart';
import 'src/ui/app_theme.dart';

Future<void> main() async {
  // First step of every run, before anything that can throw: catch what would
  // otherwise die in silence. A window that never appears leaves no window to
  // show a banner in, so the log file is the only account of why.
  runZonedGuarded(
    _boot,
    (error, stack) => SessionLog.write('=== 启动异常 $error\n$stack'),
  );
}

Future<void> _boot() async {
  // Which executable is this? Two builds can sit side by side (dist/ and
  // build/), and "I launched the old one" then looks exactly like "the fix did
  // not work", so this line is the proof of which build actually ran.
  SessionLog.write('=== 启动 ${File(Platform.resolvedExecutable).path}');

  // Anything thrown on the platform thread or in an unawaited future used to
  // vanish: no banner, no log, nothing to look at. Record it and keep the app
  // alive so the window can at least say what broke.
  PlatformDispatcher.instance.onError = (error, stack) {
    SessionLog.write('=== 未捕获异常 $error\n$stack');
    return true;
  };
  FlutterError.onError = (details) {
    SessionLog.write(
      '=== 界面异常 ${details.exceptionAsString()}\n${details.stack}',
    );
    FlutterError.presentError(details);
  };

  WidgetsFlutterBinding.ensureInitialized();
  PcThemeSettings.instance.init();
  runApp(const DexLinkApp());
}

class DexLinkApp extends StatelessWidget {
  const DexLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PcThemeSettings.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'DexLink',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: PcThemeSettings.instance.themeMode,
          home: const ConnectPage(),
        );
      },
    );
  }
}
