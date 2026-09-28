#include "flutter_window.h"

#include <shellapi.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::string WideStringToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }

  const int size_needed = WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (size_needed <= 0) {
    return "";
  }

  std::string converted(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), converted.data(),
                      size_needed, nullptr, nullptr);
  return converted;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  window_drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "epub_translator/window_drop",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (GetHandle()) {
    DragAcceptFiles(GetHandle(), FALSE);
  }
  window_drop_channel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_DROPFILES: {
      HDROP drop_handle = reinterpret_cast<HDROP>(wparam);
      const UINT file_count = DragQueryFileW(drop_handle, 0xFFFFFFFF, nullptr, 0);
      if (file_count > 0) {
        const UINT path_length = DragQueryFileW(drop_handle, 0, nullptr, 0);
        std::vector<wchar_t> file_path(path_length + 1);
        if (DragQueryFileW(drop_handle, 0, file_path.data(),
                           static_cast<UINT>(file_path.size())) > 0) {
          // Product semantics: the app imports exactly one book per drop —
          // always the first file — and Dart uses fileCount to tell the
          // user the rest were ignored instead of silently dropping them.
          // This is deliberate (one translation run == one book), not a
          // limitation to "fix" later by importing all files.
          SendDroppedFilePath(std::wstring(file_path.data()), file_count);
        }
      }
      DragFinish(drop_handle);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::SendDroppedFilePath(const std::wstring& file_path,
                                       UINT file_count) {
  if (!window_drop_channel_) {
    return;
  }

  // Map payload (not a bare string) so the Dart side can distinguish a
  // multi-file drop from a single file. The legacy bare-string form is
  // still accepted by Dart for forward/backward compatibility.
  flutter::EncodableMap args;
  args[flutter::EncodableValue("path")] =
      flutter::EncodableValue(WideStringToUtf8(file_path));
  args[flutter::EncodableValue("fileCount")] =
      flutter::EncodableValue(static_cast<int32_t>(file_count));
  window_drop_channel_->InvokeMethod(
      "fileDropped", std::make_unique<flutter::EncodableValue>(args));
}
