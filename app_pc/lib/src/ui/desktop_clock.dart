import 'dart:async';

import 'package:flutter/material.dart';

import 'desktop_style.dart';

Future<void> showDesktopCalendar(
  BuildContext context, {
  bool fromMenuBar = false,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x180C1428),
  builder: (context) => Theme(
    data: DesktopStyle.theme(context),
    child: Dialog(
      alignment: fromMenuBar ? Alignment.topRight : Alignment.bottomRight,
      insetPadding: fromMenuBar
          ? const EdgeInsets.fromLTRB(16, 46, 12, 16)
          : const EdgeInsets.all(16),
      child: const SizedBox(width: 350, height: 430, child: DesktopCalendar()),
    ),
  ),
);

class DesktopClock extends StatefulWidget {
  const DesktopClock({
    super.key,
    this.card = false,
    this.darkText = false,
    this.menuBar = false,
    this.compact = false,
  });
  final bool card, darkText, menuBar, compact;
  @override
  State<DesktopClock> createState() => _DesktopClockState();
}

class _DesktopClockState extends State<DesktopClock> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Tooltip(
      message: '日期和日历',
      child: InkWell(
        key: const ValueKey('desktop-clock'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => showDesktopCalendar(context, fromMenuBar: widget.menuBar),
        onSecondaryTap: () =>
            showDesktopCalendar(context, fromMenuBar: widget.menuBar),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.menuBar
                ? 8
                : widget.card
                ? 16
                : 18,
            vertical: 5,
          ),
          child: widget.menuBar
              ? Center(
                  child: Text(
                    '${widget.compact ? '' : '${now.month}月${now.day}日  周${'一二三四五六日'[now.weekday - 1]}  '}${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF353642),
                    ),
                  ),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: widget.card
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: widget.card ? 38 : 12,
                        color: widget.card || widget.darkText
                            ? const Color(0xFF24354D)
                            : Colors.white,
                        fontWeight: widget.card
                            ? FontWeight.w500
                            : FontWeight.normal,
                      ),
                    ),
                    Text(
                      '${now.month}月${now.day}日${widget.card ? '  星期${'一二三四五六日'[now.weekday - 1]}' : ''}',
                      style: TextStyle(
                        fontSize: widget.card ? 13 : 10,
                        color: widget.card || widget.darkText
                            ? const Color(0xFF62718A)
                            : Colors.white60,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class DesktopCalendar extends StatefulWidget {
  const DesktopCalendar({super.key});
  @override
  State<DesktopCalendar> createState() => _DesktopCalendarState();
}

class _DesktopCalendarState extends State<DesktopCalendar> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime selected = DateUtils.dateOnly(DateTime.now());
  void turn(int delta) =>
      setState(() => month = DateTime(month.year, month.month + delta));
  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final start = month.subtract(Duration(days: month.weekday - 1));
    return Theme(
      data: DesktopStyle.theme(context),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${month.year}年${month.month}月',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF24354D),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '上个月',
                  onPressed: () => turn(-1),
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
                IconButton(
                  tooltip: '下个月',
                  onPressed: () => turn(1),
                  icon: const Icon(Icons.chevron_right, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final day in '一二三四五六日'.split(''))
                  Expanded(
                    child: Center(
                      child: Text(
                        day,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF78859A),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisExtent: constraints.maxHeight / 6,
                  ),
                  itemCount: 42,
                  itemBuilder: (context, index) {
                    final date = DateTime(
                      start.year,
                      start.month,
                      start.day + index,
                    );
                    final active = DateUtils.isSameDay(date, selected);
                    final current = DateUtils.isSameDay(date, today);
                    return Padding(
                      padding: const EdgeInsets.all(2),
                      child: Material(
                        color: active
                            ? const Color(0xFF3D76C5)
                            : Colors.transparent,
                        shape: CircleBorder(
                          side: BorderSide(
                            color: current && !active
                                ? const Color(0xFF3D76C5)
                                : Colors.transparent,
                          ),
                        ),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => selected = date),
                          child: Center(
                            child: Text(
                              '${date.day}',
                              style: TextStyle(
                                fontSize: 12,
                                color: active
                                    ? Colors.white
                                    : date.month == month.month
                                    ? const Color(0xFF24354D)
                                    : const Color(0xFFAAB3C2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${selected.month}月${selected.day}日  星期${'一二三四五六日'[selected.weekday - 1]}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF62718A),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    selected = today;
                    month = DateTime(today.year, today.month);
                  }),
                  child: const Text('今天'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
