/// Everything that both ends must agree on.
library;

/// Bumped whenever the DexLink framing changes.
const int kDexProtocolVersion = 1;

/// TCP port the phone listens on for the video + control channels.
const int kDefaultTcpPort = 27190;

/// UDP port used for zero-config LAN discovery.
const int kDiscoveryPort = 27191;

/// Magic prefix for discovery datagrams.
const String kDiscoveryMagic = 'DEXLINK/1';

/// DexLink sends the device name in a fixed 64-byte, NUL padded field.
const int kDeviceNameLength = 64;

/// Every video packet is preceded by: pts+flags (8 bytes) + size (4 bytes).
const int kFrameHeaderLength = 12;

/// Packet flag: this packet carries codec configuration (SPS/PPS), not a frame.
const int kFrameFlagConfig = 1 << 62;

/// Packet flag: the packet is a key frame.
const int kFrameFlagKeyFrame = 1 << 61;

/// Video codec identifiers.
const int kCodecH264 = 0x68323634; // 'h264'
const int kCodecH265 = 0x68323635; // 'h265'
const int kCodecAv1 = 0x00617631; // 'av1\0'

/// Control message types (client -> device).
abstract final class ControlType {
  static const int injectKeycode = 0;
  static const int injectText = 1;
  static const int injectTouch = 2;
  static const int injectScroll = 3;
  static const int backOrScreenOn = 4;
  static const int expandNotificationPanel = 5;
  static const int expandSettingsPanel = 6;
  static const int collapsePanels = 7;
  static const int getClipboard = 8;
  static const int setClipboard = 9;
  static const int setDisplayPower = 10;
  static const int rotateDevice = 11;
  static const int uhidCreate = 12;
  static const int uhidInput = 13;
  static const int uhidDestroy = 14;
  static const int openHardKeyboardSettings = 15;
  static const int startApp = 16;
  static const int resetVideo = 17;
  static const int cameraSetTorch = 18;
  static const int cameraZoomIn = 19;
  static const int cameraZoomOut = 20;
  static const int resizeDisplay = 21;
  static const int scanFile = 22;
}

/// Device message types (device -> client), sent on the control socket.
abstract final class DeviceMessageType {
  static const int clipboard = 0;
  static const int ackClipboard = 1;
  static const int uhidOutput = 2;
  static const int panelPowerResult = 20;
}

/// `MotionEvent` actions.
abstract final class MotionAction {
  static const int down = 0;
  static const int up = 1;
  static const int move = 2;
  static const int cancel = 3;
  static const int outside = 4;
  static const int pointerDown = 5;
  static const int pointerUp = 6;
  static const int hoverMove = 7;
  static const int hoverEnter = 9;
  static const int hoverExit = 10;
}

/// `KeyEvent` actions.
abstract final class KeyAction {
  static const int down = 0;
  static const int up = 1;
}

/// A subset of Android's `MotionEvent` button constants.
abstract final class MotionButton {
  static const int primary = 1;
  static const int secondary = 2;
  static const int tertiary = 4;
  static const int back = 8;
  static const int forward = 16;
}

/// Metakey bits used in `KeyEvent.metaState`.
abstract final class MetaState {
  static const int none = 0;
  static const int shift = 0x01;
  static const int alt = 0x02;
  static const int ctrl = 0x1000;
  static const int meta = 0x10000;
}

/// A subset of Android keycodes, enough to drive a desktop shell.
abstract final class AndroidKeycode {
  static const int home = 3;
  static const int back = 4;
  static const int call = 5;
  static const int dpadUp = 19;
  static const int dpadDown = 20;
  static const int dpadLeft = 21;
  static const int dpadRight = 22;
  static const int volumeUp = 24;
  static const int volumeDown = 25;
  static const int power = 26;
  static const int tab = 61;
  static const int space = 62;
  static const int enter = 66;
  static const int delete = 67;
  static const int menu = 82;
  static const int escape = 111;
  static const int forwardDel = 112;
  static const int insert = 124;
  static const int moveHome = 122;
  static const int moveEnd = 123;
  static const int pageUp = 92;
  static const int pageDown = 93;
  static const int appSwitch = 187;
  static const int cut = 277;
  static const int copy = 278;
  static const int paste = 279;
  static const int selectAll = 280;
}

/// Upper bound accepted for a single video packet (guards the parser).
const int kMaxVideoPacketSize = 32 * 1024 * 1024;
