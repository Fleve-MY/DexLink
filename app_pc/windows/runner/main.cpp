#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <dwmapi.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// The app renders a dark UI, so the non-client area has to match even when
// Windows itself is in light mode.
void ForceDarkTitleBar(HWND window) {
  BOOL dark = TRUE;
  // 20 is DWMWA_USE_IMMERSIVE_DARK_MODE on Windows 10 2004+; 19 on older builds.
  if (FAILED(DwmSetWindowAttribute(window, 20, &dark, sizeof(dark)))) {
    DwmSetWindowAttribute(window, 19, &dark, sizeof(dark));
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  for (const auto& argument : command_line_arguments) {
    if (argument == "--video-probe-skia") {
      project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  const int screen_width = ::GetSystemMetrics(SM_CXSCREEN);
  const int screen_height = ::GetSystemMetrics(SM_CYSCREEN);
  Win32Window::Size size(1280, 800);
  Win32Window::Point origin((screen_width - size.width) / 2,
                            (screen_height - size.height) / 2);
  if (!window.Create(L"DexLink", origin, size)) {
    return EXIT_FAILURE;
  }
  ForceDarkTitleBar(window.GetHandle());
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
