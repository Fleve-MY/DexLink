import 'dart:async';
import 'dart:convert';

import 'package:dex_link/dex_link.dart';
import 'package:flutter/services.dart';

import 'dex_session.dart';

/// Translates local pointer/keyboard events into DexLink control messages.
class RemoteInput {
  RemoteInput(DexSession session, {this.mouse = false}) : _session = session;

  final bool mouse;

  DexSession _session;

  /// The session actually used for sending; a reconnect swaps it without the
  /// widget layer having to care.
  DexSession get session => _session;

  /// Points this input at a new session (reconnect). The phone-side geometry
  /// is kept: it was learned from the phone, not from the socket.
  void attach(DexSession session) {
    _session = session;
  }

  /// Size of the phone-side display, in its own pixels.
  Size phoneSize = const Size(1920, 1080);

  /// Size of the widget the video is drawn into.
  Size viewSize = const Size(1920, 1080);

  bool _pressed = false;
  int _buttons = 0;

  void updateGeometry({required Size phone, required Size view}) {
    phoneSize = phone;
    viewSize = view;
  }

  ({int x, int y}) _map(Offset local) {
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      return (x: 0, y: 0);
    }
    final x = (local.dx / viewSize.width * phoneSize.width).round().clamp(
      0,
      phoneSize.width.toInt() - 1,
    );
    final y = (local.dy / viewSize.height * phoneSize.height).round().clamp(
      0,
      phoneSize.height.toInt() - 1,
    );
    return (x: x, y: y);
  }

  void pointerDown(Offset local, {int buttons = MotionButton.primary}) {
    final point = _map(local);
    _pressed = true;
    _buttons = buttons;
    session.send(
      ControlMessages.injectTouch(
        action: MotionAction.down,
        pointerId: mouse ? -1 : 0,
        x: point.x,
        y: point.y,
        screenWidth: phoneSize.width.toInt(),
        screenHeight: phoneSize.height.toInt(),
        pressure: 1.0,
        actionButton: buttons,
        buttons: buttons,
      ),
    );
  }

  void pointerMove(Offset local) {
    if (!_pressed) return;
    final point = _map(local);
    session.send(
      ControlMessages.injectTouch(
        action: MotionAction.move,
        pointerId: mouse ? -1 : 0,
        x: point.x,
        y: point.y,
        screenWidth: phoneSize.width.toInt(),
        screenHeight: phoneSize.height.toInt(),
        pressure: 1.0,
        actionButton: 0,
        buttons: _buttons,
      ),
    );
  }

  void pointerUp(Offset local) {
    if (!_pressed) return;
    _pressed = false;
    final point = _map(local);
    session.send(
      ControlMessages.injectTouch(
        action: MotionAction.up,
        pointerId: mouse ? -1 : 0,
        x: point.x,
        y: point.y,
        screenWidth: phoneSize.width.toInt(),
        screenHeight: phoneSize.height.toInt(),
        pressure: 1.0,
        actionButton: mouse ? _buttons : 0,
        buttons: 0,
      ),
    );
    _buttons = 0;
  }

  void hover(Offset local, {int action = MotionAction.hoverMove}) {
    if (!mouse || _pressed) return;
    final point = _map(local);
    session.send(
      ControlMessages.injectTouch(
        action: action,
        pointerId: -1,
        x: point.x,
        y: point.y,
        screenWidth: phoneSize.width.toInt(),
        screenHeight: phoneSize.height.toInt(),
        pressure: 0,
      ),
    );
  }

  void pointerCancel(Offset local) {
    if (!_pressed) return;
    final point = _map(local);
    _pressed = false;
    _buttons = 0;
    session.send(
      ControlMessages.injectTouch(
        action: MotionAction.cancel,
        pointerId: mouse ? -1 : 0,
        x: point.x,
        y: point.y,
        screenWidth: phoneSize.width.toInt(),
        screenHeight: phoneSize.height.toInt(),
        pressure: 0,
      ),
    );
  }

  void scroll(Offset local, Offset delta) {
    final point = _map(local);
    // One wheel notch is one unit on the phone side, and the protocol's unit range is
    // [-16, 16]; 50 logical pixels per notch feels right on Windows.
    final v = (-delta.dy / 50).clamp(-16.0, 16.0);
    final h = (delta.dx / 50).clamp(-16.0, 16.0);
    if (v == 0 && h == 0) return;
    session.send(
      ControlMessages.injectScroll(
        x: point.x,
        y: point.y,
        screenWidth: phoneSize.width.toInt(),
        screenHeight: phoneSize.height.toInt(),
        hScroll: h,
        vScroll: v,
      ),
    );
  }

  /// Returns true when the event was consumed.
  bool handleKey(KeyEvent event, {bool sendText = true}) {
    // Windows IMEs use modifier releases (for example Shift) to switch modes.
    // Do not swallow them when committed text is handled by TextInputClient.
    if (event is KeyUpEvent) return sendText;

    final keyboard = HardwareKeyboard.instance;
    final metaState = _metaState(keyboard);
    final character = event.character;
    final hasCommandModifier =
        keyboard.isControlPressed || keyboard.isAltPressed;

    // Ctrl/Cmd shortcuts need real key events so the app receives the modifier
    // together with the letter.
    if (hasCommandModifier) {
      final keycode = _letterOrDigitKeycode(event.logicalKey.keyLabel);
      if (keycode != null) {
        session.send(
          ControlMessages.injectKeycode(
            action: KeyAction.down,
            keycode: keycode,
            metaState: metaState,
          ),
        );
        session.send(
          ControlMessages.injectKeycode(
            action: KeyAction.up,
            keycode: keycode,
            metaState: metaState,
          ),
        );
        return true;
      }
    }

    if (sendText &&
        !hasCommandModifier &&
        character != null &&
        character.isNotEmpty) {
      final codeUnit = character.codeUnitAt(0);
      // Printable text goes through the text channel so that layouts and
      // IME-composed characters work without a keycode table.
      if (codeUnit >= 0x20 && codeUnit != 0x7F) {
        session.send(ControlMessages.injectText(character));
        return true;
      }
    }

    final special = _specialKeycodes[event.logicalKey];
    if (special == null) return false;
    session.send(
      ControlMessages.injectKeycode(
        action: KeyAction.down,
        keycode: special,
        metaState: metaState,
      ),
    );
    session.send(
      ControlMessages.injectKeycode(
        action: KeyAction.up,
        keycode: special,
        metaState: metaState,
      ),
    );
    return true;
  }

  int _metaState(HardwareKeyboard keyboard) {
    var state = MetaState.none;
    if (keyboard.isShiftPressed) state |= MetaState.shift;
    if (keyboard.isAltPressed) state |= MetaState.alt;
    if (keyboard.isControlPressed) state |= MetaState.ctrl;
    if (keyboard.isMetaPressed) state |= MetaState.meta;
    return state;
  }

  int? _letterOrDigitKeycode(String character) {
    if (character.length != 1) return null;
    final unit = character.toLowerCase().codeUnitAt(0);
    if (unit >= 0x61 && unit <= 0x7A) {
      return _keyA + (unit - 0x61);
    }
    if (unit >= 0x30 && unit <= 0x39) {
      return _key0 + (unit - 0x30);
    }
    return null;
  }

  static const int _keyA = 29; // KEYCODE_A
  static const int _key0 = 7; // KEYCODE_0

  static final Map<LogicalKeyboardKey, int> _specialKeycodes = {
    LogicalKeyboardKey.escape: AndroidKeycode.back,
    LogicalKeyboardKey.enter: AndroidKeycode.enter,
    LogicalKeyboardKey.numpadEnter: AndroidKeycode.enter,
    LogicalKeyboardKey.backspace: AndroidKeycode.delete,
    LogicalKeyboardKey.delete: AndroidKeycode.forwardDel,
    LogicalKeyboardKey.tab: AndroidKeycode.tab,
    LogicalKeyboardKey.arrowUp: AndroidKeycode.dpadUp,
    LogicalKeyboardKey.arrowDown: AndroidKeycode.dpadDown,
    LogicalKeyboardKey.arrowLeft: AndroidKeycode.dpadLeft,
    LogicalKeyboardKey.arrowRight: AndroidKeycode.dpadRight,
    LogicalKeyboardKey.home: AndroidKeycode.moveHome,
    LogicalKeyboardKey.end: AndroidKeycode.moveEnd,
    LogicalKeyboardKey.pageUp: AndroidKeycode.pageUp,
    LogicalKeyboardKey.pageDown: AndroidKeycode.pageDown,
    LogicalKeyboardKey.contextMenu: AndroidKeycode.menu,
    LogicalKeyboardKey.f1: 131,
    LogicalKeyboardKey.f2: 132,
    LogicalKeyboardKey.f3: 133,
    LogicalKeyboardKey.f4: 134,
    LogicalKeyboardKey.f5: 135,
    LogicalKeyboardKey.f6: 136,
    LogicalKeyboardKey.f7: 137,
    LogicalKeyboardKey.f8: 138,
    LogicalKeyboardKey.f9: 139,
    LogicalKeyboardKey.f10: 140,
    LogicalKeyboardKey.f11: 141,
    LogicalKeyboardKey.f12: 142,
  };
}

/// Convenience wrappers for the shell buttons.
extension ShellActions on DexSession {
  void tapKey(int keycode) {
    send(
      ControlMessages.injectKeycode(action: KeyAction.down, keycode: keycode),
    );
    send(ControlMessages.injectKeycode(action: KeyAction.up, keycode: keycode));
  }

  void back() {
    send(ControlMessages.backOrScreenOn(KeyAction.down));
    send(ControlMessages.backOrScreenOn(KeyAction.up));
  }

  void goHome() => tapKey(AndroidKeycode.home);

  void showRecents() => tapKey(AndroidKeycode.appSwitch);

  void rotate() => send(ControlMessages.rotateDevice());

  void volumeUp() => tapKey(AndroidKeycode.volumeUp);

  void volumeDown() => tapKey(AndroidKeycode.volumeDown);
}

/// Decodes the raw bytes of a clipboard message, used for sync.
String decodeClipboard(Uint8List bytes) =>
    utf8.decode(bytes, allowMalformed: true);

/// Kept for future use: unawaited futures in hot paths.
void ignore(Future<void> future) => unawaited(future);
