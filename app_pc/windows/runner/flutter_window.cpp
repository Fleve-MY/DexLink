#include "flutter_window.h"
#include "native_audio.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <optional>

#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr const wchar_t kHostProp[] = L"DEXLINK_FLUTTER_WINDOW_HOST";

// Same file the Dart side writes to: the executable's own folder. Using
// GetModuleFileName keeps this independent of the working directory, which is
// whatever the shortcut happened to set.
void AppendLog(const char* text) {
  wchar_t path[MAX_PATH] = {};
  const DWORD length =
      ::GetModuleFileNameW(nullptr, path, static_cast<DWORD>(MAX_PATH));
  if (length == 0 || length >= MAX_PATH) return;
  wchar_t* slash = wcsrchr(path, L'\\');
  if (slash == nullptr) return;
  wcscpy_s(slash + 1, MAX_PATH - (slash + 1 - path), L"dexlink.log");

  SYSTEMTIME now{};
  ::GetLocalTime(&now);
  FILE* file = nullptr;
  if (_wfopen_s(&file, path, L"a, ccs=UTF-8") != 0 || file == nullptr) return;
  std::fwprintf(file, L"%02d:%02d:%02d [win] %hs\n", now.wHour, now.wMinute,
                now.wSecond, text);
  std::fclose(file);
}

}  // namespace

void FlutterWindow::LogLine(const char* text) { AppendLog(text); }

void FlutterWindow::LogNcCalc(HWND hwnd, const char* phase,
                              const NCCALCSIZE_PARAMS* params, LRESULT result) {
  if (params == nullptr) return;
  RECT window{};
  ::GetWindowRect(hwnd, &window);
  char line[256] = {};
  std::snprintf(line, sizeof(line),
                "NCCALCSIZE(%s) zoomed=%d rc0=%ld,%ld,%ld,%ld "
                "rgrc1=%ld,%ld,%ld,%ld win=%ld,%ld,%ld,%ld ret=%ld n=%d",
                phase, ::IsZoomed(hwnd) ? 1 : 0,
                static_cast<long>(params->rgrc[0].left),
                static_cast<long>(params->rgrc[0].top),
                static_cast<long>(params->rgrc[0].right),
                static_cast<long>(params->rgrc[0].bottom),
                static_cast<long>(params->rgrc[1].left),
                static_cast<long>(params->rgrc[1].top),
                static_cast<long>(params->rgrc[1].right),
                static_cast<long>(params->rgrc[1].bottom),
                static_cast<long>(window.left), static_cast<long>(window.top),
                static_cast<long>(window.right),
                static_cast<long>(window.bottom), static_cast<long>(result),
                nccalc_count_);
  LogLine(line);
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

LRESULT CALLBACK FlutterWindow::ChildWndProc(HWND hwnd, UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) noexcept {
  auto* self = static_cast<FlutterWindow*>(::GetPropW(hwnd, kHostProp));
  if (self != nullptr) {
    if (message == WM_NCHITTEST && self->projection_mode_) {
      const LRESULT hit = self->HitTestEdges(self->GetHandle(), lparam);
      if (hit != HTCLIENT) {
        return HTTRANSPARENT;
      }
    }
    if (self->original_child_wndproc_ != nullptr) {
      return ::CallWindowProcW(self->original_child_wndproc_, hwnd, message,
                               wparam, lparam);
    }
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

void FlutterWindow::SyncChildContentSize() {
  if (!flutter_controller_ || !flutter_controller_->view()) return;
  HWND child = flutter_controller_->view()->GetNativeWindow();
  if (child == nullptr) return;
  RECT client = GetClientArea();
  ::MoveWindow(child, client.left, client.top, client.right - client.left,
               client.bottom - client.top, TRUE);
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  native_video_ = std::make_unique<NativeVideoBridge>(
      flutter_controller_->engine()->GetRegistrarForPlugin("DexLinkNativeVideo"));
  native_audio_ = std::make_unique<NativeAudioBridge>(flutter_controller_->engine()->messenger());
  HWND child = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child);
  if (child != nullptr) {
    ::SetPropW(child, kHostProp, this);
    original_child_wndproc_ = reinterpret_cast<WNDPROC>(::SetWindowLongPtrW(
        child, GWLP_WNDPROC,
        reinterpret_cast<LONG_PTR>(&FlutterWindow::ChildWndProc)));
  }

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dexlink/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setProjectionMode") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (enabled == nullptr) {
            result->Error("bad-args", "setProjectionMode needs a boolean");
            return;
          }
          SetProjectionMode(*enabled);
          HWND hwnd = GetHandle();
          const LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
          flutter::EncodableMap reply;
          reply[flutter::EncodableValue("projection")] =
              flutter::EncodableValue(projection_mode_);
          reply[flutter::EncodableValue("caption")] =
              flutter::EncodableValue((style & WS_CAPTION) != 0);
          reply[flutter::EncodableValue("thickframe")] =
              flutter::EncodableValue((style & WS_THICKFRAME) != 0);
          RECT rect{};
          ::GetWindowRect(hwnd, &rect);
          reply[flutter::EncodableValue("width")] =
              flutter::EncodableValue(static_cast<int32_t>(rect.right - rect.left));
          reply[flutter::EncodableValue("height")] =
              flutter::EncodableValue(static_cast<int32_t>(rect.bottom - rect.top));
          reply[flutter::EncodableValue("nccalc")] =
              flutter::EncodableValue(nccalc_count_);
          reply[flutter::EncodableValue("hittest")] =
              flutter::EncodableValue(hit_test_count_);
          reply[flutter::EncodableValue("hitedge")] =
              flutter::EncodableValue(hit_edge_count_);
          reply[flutter::EncodableValue("lasthit")] =
              flutter::EncodableValue(last_hit_);
          result->Success(flutter::EncodableValue(reply));
          return;
        }
        if (call.method_name() == "startDragging") {
          result->Success();
          ::ReleaseCapture();
          ::PostMessage(GetHandle(), WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
          return;
        }
        if (call.method_name() == "minimize") {
          ::ShowWindow(GetHandle(), SW_MINIMIZE);
          result->Success();
          return;
        }
        if (call.method_name() == "toggleMaximize") {
          ShowWindow(GetHandle(), IsZoomed(GetHandle()) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
          return;
        }
        if (call.method_name() == "resize") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("bad-args", "resize needs {width, height}");
            return;
          }
          auto w = args->find(flutter::EncodableValue("width"));
          auto h = args->find(flutter::EncodableValue("height"));
          if (w == args->end() || h == args->end() ||
              !std::holds_alternative<double>(w->second) ||
              !std::holds_alternative<double>(h->second)) {
            result->Error("bad-args", "width and height must be doubles");
            return;
          }
          if (!ResizeClient(std::get<double>(w->second),
                            std::get<double>(h->second))) {
            result->Error("failed", "could not resize the window");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() != "fitWindow") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("bad-args", "fitWindow needs {width, height, auto}");
          return;
        }
        auto width_value = arguments->find(flutter::EncodableValue("width"));
        auto height_value = arguments->find(flutter::EncodableValue("height"));
        if (width_value == arguments->end() ||
            height_value == arguments->end() ||
            !std::holds_alternative<int32_t>(width_value->second) ||
            !std::holds_alternative<int32_t>(height_value->second)) {
          result->Error("bad-args", "width and height must be integers");
          return;
        }
        bool automatic = true;
        auto auto_value = arguments->find(flutter::EncodableValue("auto"));
        if (auto_value != arguments->end() &&
            std::holds_alternative<bool>(auto_value->second)) {
          automatic = std::get<bool>(auto_value->second);
        }
        bool apply = true;
        if (automatic && last_user_move_ != 0) {
          auto now = ::GetTickCount64();
          if (now - last_user_move_ < kAutoFitGraceMs) {
            apply = false;
          }
        }
        std::pair<int, int> size{0, 0};
        if (apply) {
          size = FitToAspect(std::get<int32_t>(width_value->second),
                             std::get<int32_t>(height_value->second));
        } else {
          HWND hwnd = GetHandle();
          HMONITOR monitor =
              ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
          const double dpi_scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
          RECT client = GetClientArea();
          size = {
              static_cast<int>(
                  std::lround((client.right - client.left) / dpi_scale)),
              static_cast<int>(
                  std::lround((client.bottom - client.top) / dpi_scale)),
          };
        }
        if (size.first <= 0) {
          result->Error("failed", "could not resize the window");
          return;
        }
        flutter::EncodableMap reply;
        reply[flutter::EncodableValue("width")] =
            flutter::EncodableValue(size.first);
        reply[flutter::EncodableValue("height")] =
            flutter::EncodableValue(size.second);
        reply[flutter::EncodableValue("applied")] =
            flutter::EncodableValue(apply);
        result->Success(flutter::EncodableValue(reply));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Background renderer verification must never show or focus a window.
    if (std::wcsstr(::GetCommandLineW(), L"--video-probe") == nullptr) this->Show();
  });

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  native_audio_.reset();
  native_video_.reset();
  window_channel_.reset();
  if (flutter_controller_ && flutter_controller_->view()) {
    HWND child = flutter_controller_->view()->GetNativeWindow();
    if (child != nullptr) {
      if (original_child_wndproc_ != nullptr) {
        ::SetWindowLongPtrW(
            child, GWLP_WNDPROC,
            reinterpret_cast<LONG_PTR>(original_child_wndproc_));
        original_child_wndproc_ = nullptr;
      }
      ::RemovePropW(child, kHostProp);
    }
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetProjectionMode(bool enabled) {
  if (projection_mode_ == enabled) return;
  HWND hwnd = GetHandle();
  if (enabled) {
    saved_window_style_ = ::GetWindowLongPtr(hwnd, GWL_STYLE);
    ::GetWindowRect(hwnd, &saved_window_rect_);
    projection_mode_ = true;
    last_user_move_ = 0;
    ::SetWindowLongPtr(hwnd, GWL_STYLE,
                       saved_window_style_ & ~static_cast<LONG_PTR>(WS_CAPTION));
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                       SWP_FRAMECHANGED);
    SyncChildContentSize();

    char line[256] = {};
    RECT window_rect{};
    ::GetWindowRect(hwnd, &window_rect);
    std::snprintf(line, sizeof(line),
                  "projection ON  style=0x%08lX thickframe=%d caption=%d "
                  "maximized=%d  rect=%ldx%ld",
                  static_cast<unsigned long>(::GetWindowLongPtr(hwnd, GWL_STYLE)),
                  (::GetWindowLongPtr(hwnd, GWL_STYLE) & WS_THICKFRAME) != 0,
                  (::GetWindowLongPtr(hwnd, GWL_STYLE) & WS_CAPTION) != 0,
                  ::IsZoomed(hwnd) ? 1 : 0,
                  static_cast<long>(window_rect.right - window_rect.left),
                  static_cast<long>(window_rect.bottom - window_rect.top));
    LogLine(line);
  } else {
    projection_mode_ = false;
    ::SetWindowLongPtr(hwnd, GWL_STYLE, saved_window_style_);
    ::SetWindowPos(hwnd, nullptr, saved_window_rect_.left, saved_window_rect_.top,
                   saved_window_rect_.right - saved_window_rect_.left,
                   saved_window_rect_.bottom - saved_window_rect_.top,
                   SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    SyncChildContentSize();
  }
}

bool FlutterWindow::ResizeClient(double logical_width, double logical_height) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || logical_width < 200 || logical_height < 200) {
    return false;
  }
  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  const double dpi_scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;

  RECT window_rect{};
  RECT client_rect{};
  ::GetWindowRect(hwnd, &window_rect);
  ::GetClientRect(hwnd, &client_rect);
  const int frame_width = (window_rect.right - window_rect.left) -
                          (client_rect.right - client_rect.left);
  const int frame_height = (window_rect.bottom - window_rect.top) -
                           (client_rect.bottom - client_rect.top);

  const int physical_width =
      static_cast<int>(std::lround(logical_width * dpi_scale)) + frame_width;
  const int physical_height =
      static_cast<int>(std::lround(logical_height * dpi_scale)) + frame_height;

  ::SetWindowPos(hwnd, nullptr, 0, 0, physical_width, physical_height,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  SyncChildContentSize();
  return true;
}

std::pair<int, int> FlutterWindow::FitToAspect(int content_width,
                                               int content_height) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || content_width <= 0 || content_height <= 0) {
    return {0, 0};
  }

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (!::GetMonitorInfo(monitor, &monitor_info)) {
    return {0, 0};
  }
  const double dpi_scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;

  // Work area in logical pixels, i.e. the same units Flutter uses.
  const int work_width = static_cast<int>(
      (monitor_info.rcWork.right - monitor_info.rcWork.left) / dpi_scale);
  const int work_height = static_cast<int>(
      (monitor_info.rcWork.bottom - monitor_info.rcWork.top) / dpi_scale);

  // Reserve 74 logical pixels for the dedicated top title bar (36px) and
  // bottom navigation bar (38px) so the video area inside Expanded matches
  // the phone's aspect ratio with zero black bars and zero toolbar overlap.
  const int chrome_height = projection_mode_ ? 74 : 0;

  const double max_width = work_width * 0.72;
  const double max_video_height =
      std::max(240.0, work_height * (projection_mode_ ? 0.94 : 0.92) - chrome_height);

  double scale = std::min(max_width / content_width,
                          max_video_height / content_height);
  scale = std::min(scale, 1.0);

  RECT window_rect{};
  RECT client_rect{};
  ::GetWindowRect(hwnd, &window_rect);
  ::GetClientRect(hwnd, &client_rect);
  const int frame_width = projection_mode_
                              ? 0
                              : (window_rect.right - window_rect.left) -
                                    (client_rect.right - client_rect.left);
  const int frame_height = projection_mode_
                               ? 0
                               : (window_rect.bottom - window_rect.top) -
                                     (client_rect.bottom - client_rect.top);

  const int video_width =
      std::max(240, static_cast<int>(std::lround(content_width * scale)));
  const int video_height = std::max(
      240, static_cast<int>(std::lround(video_width *
                                        (static_cast<double>(content_height) /
                                         static_cast<double>(content_width)))));
  const int client_width = video_width;
  const int client_height = video_height + chrome_height;

  const int physical_width =
      static_cast<int>(std::lround(client_width * dpi_scale)) + frame_width;
  const int physical_height =
      static_cast<int>(std::lround(client_height * dpi_scale)) + frame_height;

  int x = window_rect.left;
  int y = window_rect.top;
  const int work_left = static_cast<int>(monitor_info.rcWork.left);
  const int work_top = static_cast<int>(monitor_info.rcWork.top);
  const int work_right = static_cast<int>(monitor_info.rcWork.right);
  const int work_bottom = static_cast<int>(monitor_info.rcWork.bottom);

  // Center the fitted window on the active monitor work area.
  x = work_left + (work_right - work_left - physical_width) / 2;
  y = work_top + (work_bottom - work_top - physical_height) / 2;
  x = std::clamp(x, work_left, std::max(work_left, work_right - physical_width));
  y = std::clamp(y, work_top, std::max(work_top, work_bottom - physical_height));

  ::SetWindowPos(hwnd, nullptr, x, y, physical_width, physical_height,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  SyncChildContentSize();

  char fit_line[160] = {};
  std::snprintf(fit_line, sizeof(fit_line),
                "FitToAspect(%dx%d) -> client=%dx%d phys=%dx%d at (%d,%d)",
                content_width, content_height, client_width, client_height,
                physical_width, physical_height, x, y);
  LogLine(fit_line);

  return {client_width, client_height};
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Eliminate the system title bar and resize-frame inset while projecting.
  // When wparam != 0, params->rgrc[0] on entry already holds the proposed new
  // window rectangle in screen coordinates. Returning 0 without modifying
  // rgrc[0] makes the client area cover the entire window bounds.
  if (projection_mode_ && message == WM_NCCALCSIZE && wparam != 0) {
    ++nccalc_count_;
    auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    if (params == nullptr) return 0;
    if (::IsZoomed(hwnd)) {
      MONITORINFO monitor_info{};
      monitor_info.cbSize = sizeof(MONITORINFO);
      if (::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                           &monitor_info)) {
        params->rgrc[0] = monitor_info.rcWork;
      }
      if (nccalc_count_ <= 8) LogNcCalc(hwnd, "max", params, 0);
      return 0;
    }
    if (nccalc_count_ <= 8) LogNcCalc(hwnd, "norm", params, 0);
    return 0;
  }

  // Keep WS_CAPTION off while in projection mode.
  if (projection_mode_ && message == WM_STYLECHANGING &&
      wparam == GWL_STYLE) {
    auto* style = reinterpret_cast<STYLESTRUCT*>(lparam);
    if (style != nullptr) {
      style->styleNew &= ~static_cast<LONG>(WS_CAPTION);
    }
  }

  // Answer WM_NCHITTEST for the borderless resize edges (reached when
  // ChildWndProc returns HTTRANSPARENT near the edges).
  if (projection_mode_ && message == WM_NCHITTEST) {
    ++hit_test_count_;
    const LRESULT hit = HitTestEdges(hwnd, lparam);
    if (hit != HTCLIENT) {
      ++hit_edge_count_;
      last_hit_ = hit;
      if (hit_edge_count_ <= 8) {
        char line[160] = {};
        std::snprintf(line, sizeof(line),
                      "NCHITTEST edge #%d -> HT%d (screen %ld,%ld)",
                      hit_edge_count_, static_cast<int>(hit),
                      static_cast<long>(GET_X_LPARAM(lparam)),
                      static_cast<long>(GET_Y_LPARAM(lparam)));
        LogLine(line);
      }
    }
    return hit;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      if (info != nullptr) {
        info->ptMinTrackSize.x = 300;
        info->ptMinTrackSize.y = 360;
      }
      return 0;
    }
    case WM_EXITSIZEMOVE:
      if (projection_mode_) {
        last_user_move_ = ::GetTickCount64();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

LRESULT FlutterWindow::HitTestEdges(HWND hwnd, LPARAM lparam) {
  RECT window{};
  if (!::GetWindowRect(hwnd, &window)) return HTNOWHERE;
  if (::IsIconic(hwnd)) return HTCLIENT;
  if (window.right <= window.left || window.bottom <= window.top) {
    return HTCLIENT;
  }

  const int x = GET_X_LPARAM(lparam);
  const int y = GET_Y_LPARAM(lparam);

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  const double dpi_scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const int grip = static_cast<int>(std::lround(kResizeGrip * dpi_scale));

  const bool near_left = x < window.left + grip;
  const bool near_right = x >= window.right - grip;
  const bool near_top = y < window.top + 3;
  const bool near_bottom = y >= window.bottom - grip;

  if (near_top && near_left) return HTTOPLEFT;
  if (near_top && near_right) return HTTOPRIGHT;
  if (near_bottom && near_left) return HTBOTTOMLEFT;
  if (near_bottom && near_right) return HTBOTTOMRIGHT;
  if (near_left) return HTLEFT;
  if (near_right) return HTRIGHT;
  if (near_top) return HTTOP;
  if (near_bottom) return HTBOTTOM;

  return HTCLIENT;
}
