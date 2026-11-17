import 'package:flutter/material.dart';

class DesktopMenuItem<T> extends PopupMenuItem<T> {
  const DesktopMenuItem({
    super.key,
    super.value,
    super.enabled,
    super.onTap,
    super.height = 36,
    required super.child,
  }) : super(padding: const EdgeInsets.symmetric(horizontal: 14));
}

class CheckedDesktopMenuItem<T> extends CheckedPopupMenuItem<T> {
  const CheckedDesktopMenuItem({
    super.key,
    super.value,
    super.enabled,
    super.checked,
    required super.child,
  }) : super(height: 36, padding: const EdgeInsets.symmetric(horizontal: 14));
}

/// One visual language for the PC desktop shell and its transient surfaces.
abstract final class DesktopStyle {
  static const surface = Color(0xFFF7F8FC);
  static const ink = Color(0xFF303440);
  static const muted = Color(0xFF747B8C);
  static const line = Color(0xFFE1E5EF);
  static const accent = Color(0xFF526CC6);
  static const barrier = Color(0x380C1428);

  static ThemeData theme(BuildContext context) {
    final base = Theme.of(context);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
      surface: surface,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: line, width: .7),
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: base.textTheme.bodyMedium?.fontFamily,
      colorScheme: scheme,
      textTheme: base.textTheme
          .apply(bodyColor: ink, displayColor: ink)
          .copyWith(
            bodyMedium: base.textTheme.bodyMedium?.copyWith(
              fontSize: 13,
              color: ink,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontSize: 14,
              color: ink,
            ),
          ),
      iconTheme: const IconThemeData(color: muted, size: 18),
      visualDensity: VisualDensity.compact,
      hoverColor: const Color(0x10526CC6),
      splashFactory: NoSplash.splashFactory,
      dividerTheme: const DividerThemeData(
        color: line,
        thickness: .7,
        space: 12,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: const Color(0x35303D68),
        elevation: 8,
        shape: shape,
        menuPadding: const EdgeInsets.symmetric(vertical: 6),
        textStyle: TextStyle(
          fontFamily: base.textTheme.bodyMedium?.fontFamily,
          fontSize: 13,
          color: ink,
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: base.textTheme.bodyMedium?.fontFamily,
            fontSize: 13,
            color: states.contains(WidgetState.disabled)
                ? const Color(0xFF9EA4B1)
                : ink,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        barrierColor: const Color(0x380C1428),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xC0FFFFFF)),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        contentTextStyle: const TextStyle(fontSize: 13, color: ink),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: muted,
          hoverColor: const Color(0x14526CC6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: TextStyle(
            fontFamily: base.textTheme.bodyMedium?.fontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFEEF0F6),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// Shared header, spacing and edge treatment for desktop panels.
class DesktopPanel extends StatelessWidget {
  const DesktopPanel({
    super.key,
    this.title,
    required this.closeLabel,
    required this.child,
    this.actions = const [],
    this.width = 720,
    this.height = 540,
  });
  final String? title;
  final String closeLabel;
  final List<Widget> actions;
  final Widget child;
  final double width, height;

  @override
  Widget build(BuildContext context) => Theme(
    data: DesktopStyle.theme(context),
    child: Dialog(
      insetPadding: const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: title == null
                  ? const EdgeInsets.fromLTRB(12, 4, 8, 0)
                  : const EdgeInsets.fromLTRB(22, 14, 12, 12),
              child: Row(
                children: [
                  if (title == null) const Spacer(),
                  if (title != null)
                    Expanded(
                      child: Text(
                        title!,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: DesktopStyle.ink,
                        ),
                      ),
                    ),
                  ...actions,
                  IconButton(
                    tooltip: closeLabel,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
            if (title != null) const Divider(height: 1),
            Expanded(child: child),
          ],
        ),
      ),
    ),
  );
}
