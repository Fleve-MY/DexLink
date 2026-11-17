#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <utility>

#include <windows.h>

#include "win32_window.h"
#include "native_video.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Projection uses only the Flutter canvas and its edge-revealed controls.
  bool projection_mode_ = false;
  LONG_PTR saved_window_style_ = 0;
  RECT saved_window_rect_{};
  void SetProjectionMode(bool enabled);

  // Resizes the window so that its client area has the aspect ratio of the
  // phone screen, as large as the current monitor allows without upscaling.
  // A portrait phone docks to the right edge of the work area, a landscape one
  // is centred. Returns the resulting client size in logical pixels (0, 0 on
  // failure).
  std::pair<int, int> FitToAspect(int content_width, int content_height);

  // Gap between a docked window and the edge of the work area, in physical
  // pixels.
  static constexpr int kDockGap = 12;

  // Resizes the window so that its client area is exactly the given size in
  // logical pixels, keeping the current position. Undoes a FitToAspect.
  bool ResizeClient(double logical_width, double logical_height);

  // An automatic fit this soon after the user moved the window is skipped.
  static constexpr unsigned long long kAutoFitGraceMs = 8000;
  unsigned long long last_user_move_ = 0;

  // Depth, in logical pixels, of the invisible grab border along every edge and
  // corner while projecting. See HitTestEdges for why it has to be manual.
  static constexpr int kResizeGrip = 4;

  // Returns the HT* code for the point in |lparam| so the edges and corners of
  // a captionless window still resize the way a framed window does.
  LRESULT HitTestEdges(HWND hwnd, LPARAM lparam);

  // Subclasses the Flutter child HWND so that WM_NCHITTEST near the window
  // edges returns HTTRANSPARENT in projection mode, letting the parent window
  // handle native edge/corner resizing without eating client mouse events.
  static LRESULT CALLBACK ChildWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) noexcept;
  WNDPROC original_child_wndproc_ = nullptr;
  void SyncChildContentSize();

  // Appends one line to dexlink.log.
  static void LogLine(const char* text);

  // Writes the proposed and the resulting client rectangle of one
  // WM_NCCALCSIZE call.
  void LogNcCalc(HWND hwnd, const char* phase,
                 const NCCALCSIZE_PARAMS* params, LRESULT result);

  int nccalc_count_ = 0;
  int hit_test_count_ = 0;
  int hit_edge_count_ = 0;
  LRESULT last_hit_ = HTCLIENT;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<NativeVideoBridge> native_video_;
  std::unique_ptr<class NativeAudioBridge> native_audio_;

  // Small control surface for the Dart side: dexlink/window.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
