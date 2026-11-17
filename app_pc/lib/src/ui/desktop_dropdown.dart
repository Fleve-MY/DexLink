import 'package:flutter/material.dart';

class DropdownOption<T> {
  const DropdownOption({
    required this.value,
    required this.label,
    this.description,
  });

  final T value;
  final String label;
  final String? description;
}

class DesktopDropdown<T> extends StatelessWidget {
  const DesktopDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownOption<T>> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final currentOption = options.firstWhere(
      (o) => o.value == value,
      orElse: () => options.first,
    );

    final borderColor = isDark ? const Color(0xFF222F47) : const Color(0xFFCBD5E1);
    final surfaceColor = isDark ? const Color(0xFF0F1420) : const Color(0xFFF8FAFC);
    final menuBgColor = isDark ? const Color(0xFF131926) : Colors.white;
    final menuBorderColor = isDark ? const Color(0xFF222F47) : const Color(0xFFE2E8F0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.maxWidth;

        return Theme(
          data: theme.copyWith(
            popupMenuTheme: PopupMenuThemeData(
              color: menuBgColor,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: menuBorderColor),
              ),
            ),
          ),
          child: PopupMenuButton<T>(
            tooltip: '',
            offset: const Offset(0, 56), // 展开在输入框正下方，绝不遮挡上方标题和输入框自身
            constraints: BoxConstraints(
              minWidth: boxWidth,
              maxWidth: boxWidth,
            ),
            initialValue: value,
            onSelected: onChanged,
            itemBuilder: (context) {
              return [
                for (final option in options)
                  PopupMenuItem<T>(
                    value: option.value,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Builder(
                      builder: (context) {
                        final isSelected = option.value == value;
                        return Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    option.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                      color: isSelected
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  if (option.description != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      option.description!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (isSelected) ...[
                              const SizedBox(width: 8),
                              Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
              ];
            },
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: borderColor),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          currentOption.label,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.unfold_more_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
