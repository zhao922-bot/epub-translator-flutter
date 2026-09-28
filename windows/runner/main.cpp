#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Resolve relative file arguments against the ORIGINAL working directory
  // before the CWD switch below: after SetCurrentDirectoryW, a relative
  // argument (a book dragged onto the exe, or a command line issued from
  // another directory) would silently resolve against the exe directory
  // instead of where the user launched the app. Only existing relative
  // file paths are rewritten; flags and non-existent paths are untouched
  // (see ResolveRelativeFileArguments).
  std::vector<std::string> command_line_arguments =
      ResolveRelativeFileArguments(GetCommandLineArguments());

  // Run with the executable's directory as the working directory, so that the
  // relative "data" path below resolves no matter how the app was launched
  // (a shortcut with a wrong "Start in" directory, a command line issued from
  // another directory, or a third-party launcher). Best effort: if the path
  // cannot be determined, behavior is unchanged from before.
  //
  // The buffer grows dynamically because an exe path can exceed MAX_PATH
  // (e.g. a deeply nested portable install): GetModuleFileNameW silently
  // truncates into a fixed MAX_PATH buffer, which would then make
  // SetCurrentDirectoryW point at a non-existent directory.
  std::vector<wchar_t> exe_path(MAX_PATH);
  DWORD exe_path_len = 0;
  bool have_exe_dir = false;
  for (;;) {
    exe_path_len =
        ::GetModuleFileNameW(nullptr, exe_path.data(),
                             static_cast<DWORD>(exe_path.size()));
    if (exe_path_len == 0) {
      // Failed: give up (fail open).
      break;
    }
    if (exe_path_len < exe_path.size() - 1) {
      // Fit: the return is the length without the terminator, so a value
      // below capacity - 1 guarantees no truncation. (Some Windows versions
      // return exactly capacity on truncation; the strict -1 comparison
      // treats that as truncated and grows.)
      have_exe_dir = true;
      break;
    }
    if (exe_path.size() >= 32768) {
      // Sanity cap: \\?\ extended paths top out at 32767 characters, so a
      // still-truncated result here means something is deeply wrong; fail
      // open rather than using a truncated directory.
      break;
    }
    exe_path.resize(exe_path.size() * 2);
  }
  if (have_exe_dir) {
    std::wstring exe_dir(exe_path.data(), exe_path_len);
    const size_t sep = exe_dir.find_last_of(L"\\/");
    if (sep != std::wstring::npos) {
      ::SetCurrentDirectoryW(exe_dir.substr(0, sep).c_str());
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Already resolved against the launch directory above; moving them here
  // keeps the set_dart_entrypoint_arguments call next to the project setup.
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"EPUB Translator", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
