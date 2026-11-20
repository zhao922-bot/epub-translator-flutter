#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"
#include "windows_platform_bridge.h"

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
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_drop_channel_;
  std::unique_ptr<WindowsPlatformBridge> windows_platform_bridge_;
  WindowDropTarget* drop_target_ = nullptr;
  HWND drop_child_hwnd_ = nullptr;
  bool ole_drop_registered_ = false;
  bool ole_child_drop_registered_ = false;

  void SendDroppedFilePath(const std::wstring& file_path, UINT file_count);
  void SendDragState(bool entered, UINT file_count);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
