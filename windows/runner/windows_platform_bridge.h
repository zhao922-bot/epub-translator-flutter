#ifndef RUNNER_WINDOWS_PLATFORM_BRIDGE_H_
#define RUNNER_WINDOWS_PLATFORM_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <oleidl.h>
#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// Registers native Win32/COM implementations for DPAPI secrets, modal file/folder
// pickers owned by |hwnd|, elevation check, and LongPathsEnabled policy query.
class WindowsPlatformBridge {
 public:
  explicit WindowsPlatformBridge(HWND hwnd, flutter::BinaryMessenger* messenger);
  ~WindowsPlatformBridge();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND hwnd_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

// OLE IDropTarget for |hwnd| forwarding dragEntered / dragExited / fileDropped
// to the Dart window_drop MethodChannel.
class WindowDropTarget final : public IDropTarget {
 public:
  using DropCallback =
      std::function<void(const std::wstring& first_path, UINT file_count)>;
  using DragStateCallback =
      std::function<void(bool entered, UINT file_count)>;

  WindowDropTarget(DropCallback on_drop, DragStateCallback on_drag_state);

  // IUnknown:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppv_object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IDropTarget:
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data_obj, DWORD key_state,
                                      POINTL pt, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL pt,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data_obj, DWORD key_state,
                                 POINTL pt, DWORD* effect) override;

 private:
  ~WindowDropTarget() = default;

  bool InspectDataObject(IDataObject* data_obj, UINT* out_count,
                         std::wstring* out_first_path);

  LONG ref_count_ = 1;
  bool has_valid_drop_ = false;
  DropCallback on_drop_;
  DragStateCallback on_drag_state_;
};

std::string WideToUtf8(const std::wstring& value);
std::wstring Utf8ToWide(const std::string& value);

#endif  // RUNNER_WINDOWS_PLATFORM_BRIDGE_H_
