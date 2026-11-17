import 'package:flutter/material.dart';

import '../desktop_items.dart';

class DesktopTodo extends StatefulWidget {
  const DesktopTodo({super.key, required this.item, required this.store});
  final Map<String, dynamic> item;
  final DesktopItems store;
  @override
  State<DesktopTodo> createState() => _DesktopTodoState();
}

class _DesktopTodoState extends State<DesktopTodo> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void add() {
    if (input.text.trim().isEmpty ||
        (widget.item['tasks'] as List? ?? []).length >= 100) {
      return;
    }
    widget.store.addWidgetTask(widget.item['id'] as String, input.text);
    input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = (widget.item['tasks'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final done = tasks.where((task) => task['done'] == true).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$done / ${tasks.length} 项已完成',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF62718A),
                  ),
                ),
              ),
              if (done > 0)
                TextButton(
                  onPressed: () =>
                      widget.store.updateWidget(widget.item['id'] as String, {
                        'tasks': tasks
                            .where((task) => task['done'] != true)
                            .toList(),
                      }),
                  child: const Text('清除已完成'),
                ),
            ],
          ),
          Expanded(
            child: tasks.isEmpty
                ? const Center(
                    child: Text(
                      '把今天要做的事记在这里',
                      style: TextStyle(fontSize: 12, color: Color(0xFF62718A)),
                    ),
                  )
                : ListView.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final task = tasks[index],
                          checked = tasks[index]['done'] == true;
                      return Row(
                        children: [
                          Checkbox(
                            value: checked,
                            visualDensity: VisualDensity.compact,
                            onChanged: (value) => widget.store.updateWidgetTask(
                              widget.item['id'] as String,
                              task['id'] as String,
                              done: value,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '${task['label']}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: checked
                                    ? const Color(0xFF8B95A5)
                                    : const Color(0xFF24354D),
                                decoration: checked
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '删除待办',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => widget.store.updateWidgetTask(
                              widget.item['id'] as String,
                              task['id'] as String,
                              remove: true,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  maxLength: 200,
                  onSubmitted: (_) => add(),
                  decoration: const InputDecoration(
                    hintText: '添加待办…',
                    counterText: '',
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: '添加待办事项',
                onPressed: tasks.length < 100 ? add : null,
                icon: const Icon(Icons.add, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
