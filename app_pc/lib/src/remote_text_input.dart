import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Characters;

/// Receives committed Windows text, including IME compositions. Raw control
/// keys remain on the remote keyboard path; uncommitted candidates stay local.
class RemoteTextInput with TextInputClient {
  RemoteTextInput(this.onText, {required this.viewId, required this.onDelete});

  final ValueChanged<String> onText;
  final ValueChanged<int> onDelete;
  final int Function() viewId;
  TextInputConnection? _connection;
  static const _empty = TextEditingValue(
    selection: TextSelection.collapsed(offset: 0),
  );
  TextEditingValue _value = _empty;
  String _committedText = '';
  Size _size = const Size(1, 1);
  Matrix4 _transform = Matrix4.identity();
  Rect _caret = const Rect.fromLTWH(0, 0, 1, 20);
  bool get composing =>
      _value.composing.isValid && !_value.composing.isCollapsed;

  void focus(bool focused) {
    if (!focused) {
      _connection?.close();
      _connection = null;
      _value = _empty;
      _committedText = '';
    } else if (_connection?.attached != true) {
      _connection = TextInput.attach(
        this,
        TextInputConfiguration(
          viewId: viewId(),
          inputType: TextInputType.text,
          autocorrect: false,
          enableSuggestions: false,
          inputAction: TextInputAction.none,
        ),
      );
      _connection!.setEditingState(_value);
      _sendGeometry();
      _connection!.show();
    }
  }

  // Windows TSF needs a valid client/caret rectangle to place IME candidates.
  void setGeometry(Size size, Matrix4 transform, Rect caret) {
    _size = size;
    _transform = transform;
    _caret = caret;
    _sendGeometry();
  }

  void _sendGeometry() {
    final connection = _connection;
    if (connection?.attached != true) return;
    connection!.setEditableSizeAndTransform(_size, _transform);
    connection.setCaretRect(_caret);
    connection.setComposingRect(_caret);
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    if (composing) return;
    // TSF reports a complete editing buffer, not just the latest insertion.
    // Clearing it after each update can race the next preedit update and
    // replay growing prefixes (t, ti, tin...). Keep the buffer until a remote
    // caret/control action changes the editing context.
    final previous = Characters(_committedText).toList();
    final next = Characters(value.text).toList();
    var common = 0;
    while (common < previous.length &&
        common < next.length &&
        previous[common] == next[common]) {
      common++;
    }
    _committedText = value.text;
    final removed = previous.length - common;
    if (removed > 0) onDelete(removed);
    if (common < next.length) onText(next.skip(common).join());
  }

  // Raw navigation/edit keys are applied on Android. Start a fresh local
  // context so its next edit cannot replace text at the previous remote caret.
  void reset() {
    _value = _empty;
    _committedText = '';
    _connection?.setEditingState(_value);
  }

  @override
  void connectionClosed() {
    _connection?.connectionClosedReceived();
    _connection = null;
    _value = _empty;
    _committedText = '';
  }

  void dispose() => focus(false);
  @override
  void performAction(TextInputAction action) {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
}
