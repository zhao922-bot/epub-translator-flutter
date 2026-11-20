#include "windows_platform_bridge.h"

#include <dpapi.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wincrypt.h>

#include <atomic>
#include <cstdint>
#include <vector>

namespace {

std::string FormatWin32Error(const char* prefix, DWORD code) {
  return std::string(prefix) + " (Win32 error " + std::to_string(code) + ")";
}

std::string FormatHResultError(const char* prefix, HRESULT hr) {
  return std::string(prefix) + " (HRESULT 0x" +
         std::to_string(static_cast<unsigned long>(hr)) + ")";
}

bool ProtectSecretUtf8(const std::string& plain_utf8,
                       std::string* out_base64,
                       std::string* out_error) {
  DATA_BLOB data_in{};
  data_in.cbData = static_cast<DWORD>(plain_utf8.size());
  data_in.pbData =
      plain_utf8.empty()
          ? nullptr
          : reinterpret_cast<BYTE*>(const_cast<char*>(plain_utf8.data()));

  DATA_BLOB data_out{};
  if (!::CryptProtectData(&data_in, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &data_out)) {
    *out_error = FormatWin32Error("CryptProtectData failed", ::GetLastError());
    return false;
  }

  DWORD b64_len = 0;
  if (!::CryptBinaryToStringA(data_out.pbData, data_out.cbData,
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                              nullptr, &b64_len) ||
      b64_len == 0) {
    ::LocalFree(data_out.pbData);
    *out_error = FormatWin32Error("CryptBinaryToStringA size failed",
                                  ::GetLastError());
    return false;
  }

  std::vector<char> b64_buf(b64_len);
  if (!::CryptBinaryToStringA(data_out.pbData, data_out.cbData,
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                              b64_buf.data(), &b64_len)) {
    ::LocalFree(data_out.pbData);
    *out_error = FormatWin32Error("CryptBinaryToStringA failed",
                                  ::GetLastError());
    return false;
  }
  ::LocalFree(data_out.pbData);

  // b64_len includes null terminator on size query, excludes it on write.
  *out_base64 = std::string(b64_buf.data(), b64_len);
  return true;
}

bool UnprotectSecretBase64(const std::string& encrypted_base64,
                           std::string* out_plain_utf8,
                           std::string* out_error) {
  if (encrypted_base64.empty()) {
    out_plain_utf8->clear();
    return true;
  }

  DWORD bin_len = 0;
  if (!::CryptStringToBinaryA(encrypted_base64.c_str(),
                              static_cast<DWORD>(encrypted_base64.size()),
                              CRYPT_STRING_BASE64, nullptr, &bin_len, nullptr,
                              nullptr) ||
      bin_len == 0) {
    *out_error = FormatWin32Error("Invalid base64 DPAPI payload",
                                  ::GetLastError());
    return false;
  }

  std::vector<BYTE> bin_buf(bin_len);
  if (!::CryptStringToBinaryA(encrypted_base64.c_str(),
                              static_cast<DWORD>(encrypted_base64.size()),
                              CRYPT_STRING_BASE64, bin_buf.data(), &bin_len,
                              nullptr, nullptr)) {
    *out_error = FormatWin32Error("CryptStringToBinaryA failed",
                                  ::GetLastError());
    return false;
  }

  DATA_BLOB data_in{};
  data_in.cbData = bin_len;
  data_in.pbData = bin_buf.data();
  DATA_BLOB data_out{};
  if (!::CryptUnprotectData(&data_in, nullptr, nullptr, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &data_out)) {
    *out_error = FormatWin32Error("CryptUnprotectData failed", ::GetLastError());
    return false;
  }

  out_plain_utf8->assign(reinterpret_cast<const char*>(data_out.pbData),
                         data_out.cbData);
  ::SecureZeroMemory(data_out.pbData, data_out.cbData);
  ::LocalFree(data_out.pbData);
  return true;
}

bool OpenFileOrFolderDialog(HWND owner, bool pick_folder,
                            std::wstring* out_path, bool* out_cancelled,
                            std::string* out_error) {
  *out_cancelled = false;
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    *out_error = FormatHResultError("CoCreateInstance(FileOpenDialog) failed", hr);
    return false;
  }

  DWORD options = 0;
  hr = dialog->GetOptions(&options);
  if (SUCCEEDED(hr)) {
    options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
    if (pick_folder) {
      options |= FOS_PICKFOLDERS;
    } else {
      options |= FOS_FILEMUSTEXIST;
    }
    dialog->SetOptions(options);
  }

  if (pick_folder) {
    dialog->SetTitle(L"Choose output directory");
  } else {
    dialog->SetTitle(L"Choose EPUB");
    const COMDLG_FILTERSPEC filters[] = {
        {L"EPUB files (*.epub)", L"*.epub"},
        {L"All files (*.*)", L"*.*"},
    };
    dialog->SetFileTypes(2, filters);
    dialog->SetFileTypeIndex(1);
    dialog->SetDefaultExtension(L"epub");
  }

  hr = dialog->Show(owner);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    dialog->Release();
    *out_cancelled = true;
    return true;
  }
  if (FAILED(hr)) {
    dialog->Release();
    *out_error = FormatHResultError("IFileOpenDialog::Show failed", hr);
    return false;
  }

  IShellItem* item = nullptr;
  hr = dialog->GetResult(&item);
  dialog->Release();
  if (FAILED(hr) || item == nullptr) {
    *out_error = FormatHResultError("IFileOpenDialog::GetResult failed", hr);
    return false;
  }

  PWSTR file_path = nullptr;
  hr = item->GetDisplayName(SIGDN_FILESYSPATH, &file_path);
  item->Release();
  if (FAILED(hr) || file_path == nullptr) {
    *out_error = FormatHResultError("IShellItem::GetDisplayName failed", hr);
    return false;
  }

  *out_path = file_path;
  ::CoTaskMemFree(file_path);
  return true;
}

bool QueryIsProcessElevated(bool* out_elevated) {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation{};
  DWORD size = sizeof(elevation);
  const BOOL ok = ::GetTokenInformation(token, TokenElevation, &elevation,
                                        sizeof(elevation), &size);
  ::CloseHandle(token);
  if (!ok) {
    return false;
  }
  *out_elevated = (elevation.TokenIsElevated != 0);
  return true;
}

// Returns 1 = enabled, 0 = disabled/missing, -1 = read error.
int QueryLongPathsEnabled() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  const LONG status = ::RegGetValueW(
      HKEY_LOCAL_MACHINE,
      L"SYSTEM\\CurrentControlSet\\Control\\FileSystem",
      L"LongPathsEnabled", RRF_RT_REG_DWORD, nullptr, &value, &size);
  if (status == ERROR_SUCCESS) {
    return value == 1 ? 1 : 0;
  }
  if (status == ERROR_FILE_NOT_FOUND) {
    return 0;
  }
  return -1;
}

}  // namespace

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size_needed = ::WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (size_needed <= 0) {
    return "";
  }
  std::string converted(static_cast<size_t>(size_needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), converted.data(),
                        size_needed, nullptr, nullptr);
  return converted;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size_needed = ::MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
  if (size_needed <= 0) {
    return L"";
  }
  std::wstring converted(static_cast<size_t>(size_needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), converted.data(),
                        size_needed);
  return converted;
}

WindowsPlatformBridge::WindowsPlatformBridge(
    HWND hwnd, flutter::BinaryMessenger* messenger)
    : hwnd_(hwnd) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "epub_translator/windows_native",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

WindowsPlatformBridge::~WindowsPlatformBridge() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_ = nullptr;
  }
}

void WindowsPlatformBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "protectSecret") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("INVALID_ARGS", "Missing arguments map");
      return;
    }
    const auto it = args->find(flutter::EncodableValue("value"));
    if (it == args->end()) {
      result->Error("INVALID_ARGS", "Missing 'value'");
      return;
    }
    const auto* plain = std::get_if<std::string>(&it->second);
    if (plain == nullptr) {
      result->Error("INVALID_ARGS", "'value' must be a string");
      return;
    }
    std::string encrypted;
    std::string error;
    if (!ProtectSecretUtf8(*plain, &encrypted, &error)) {
      result->Error("DPAPI_PROTECT_FAILED", error);
      return;
    }
    result->Success(flutter::EncodableValue(encrypted));
    return;
  }

  if (method == "unprotectSecret") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("INVALID_ARGS", "Missing arguments map");
      return;
    }
    const auto it = args->find(flutter::EncodableValue("encrypted"));
    if (it == args->end()) {
      result->Error("INVALID_ARGS", "Missing 'encrypted'");
      return;
    }
    const auto* encrypted = std::get_if<std::string>(&it->second);
    if (encrypted == nullptr) {
      result->Error("INVALID_ARGS", "'encrypted' must be a string");
      return;
    }
    std::string plain;
    std::string error;
    if (!UnprotectSecretBase64(*encrypted, &plain, &error)) {
      result->Error("DPAPI_UNPROTECT_FAILED", error);
      return;
    }
    result->Success(flutter::EncodableValue(plain));
    return;
  }

  if (method == "pickEpubFile" || method == "pickDirectory") {
    std::wstring selected_path;
    bool cancelled = false;
    std::string error;
    const bool pick_folder = (method == "pickDirectory");
    if (!OpenFileOrFolderDialog(hwnd_, pick_folder, &selected_path, &cancelled,
                                &error)) {
      result->Error("DIALOG_FAILED", error);
      return;
    }
    if (cancelled || selected_path.empty()) {
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(WideToUtf8(selected_path)));
    return;
  }

  if (method == "isProcessElevated") {
    bool elevated = false;
    if (!QueryIsProcessElevated(&elevated)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    result->Success(flutter::EncodableValue(elevated));
    return;
  }

  if (method == "isLongPathsEnabled") {
    const int policy = QueryLongPathsEnabled();
    if (policy < 0) {
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(policy == 1));
    return;
  }

  result->NotImplemented();
}

WindowDropTarget::WindowDropTarget(DropCallback on_drop,
                                   DragStateCallback on_drag_state)
    : on_drop_(std::move(on_drop)),
      on_drag_state_(std::move(on_drag_state)) {}

HRESULT STDMETHODCALLTYPE WindowDropTarget::QueryInterface(REFIID riid,
                                                         void** ppv_object) {
  if (ppv_object == nullptr) {
    return E_POINTER;
  }
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *ppv_object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *ppv_object = nullptr;
  return E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE WindowDropTarget::AddRef() {
  return static_cast<ULONG>(::InterlockedIncrement(&ref_count_));
}

ULONG STDMETHODCALLTYPE WindowDropTarget::Release() {
  const LONG next = ::InterlockedDecrement(&ref_count_);
  if (next == 0) {
    delete this;
  }
  return static_cast<ULONG>(next);
}

bool WindowDropTarget::InspectDataObject(IDataObject* data_obj,
                                         UINT* out_count,
                                         std::wstring* out_first_path) {
  if (data_obj == nullptr) {
    return false;
  }
  FORMATETC fmt{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  if (data_obj->QueryGetData(&fmt) != S_OK) {
    return false;
  }
  STGMEDIUM medium{};
  if (FAILED(data_obj->GetData(&fmt, &medium))) {
    return false;
  }
  bool ok = false;
  HDROP hdrop = static_cast<HDROP>(::GlobalLock(medium.hGlobal));
  if (hdrop != nullptr) {
    const UINT count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
    if (count > 0) {
      *out_count = count;
      if (out_first_path != nullptr) {
        const UINT path_len = ::DragQueryFileW(hdrop, 0, nullptr, 0);
        std::vector<wchar_t> buf(path_len + 1);
        if (::DragQueryFileW(hdrop, 0, buf.data(),
                             static_cast<UINT>(buf.size())) > 0) {
          *out_first_path = buf.data();
        }
      }
      ok = true;
    }
    ::GlobalUnlock(medium.hGlobal);
  }
  ::ReleaseStgMedium(&medium);
  return ok;
}

HRESULT STDMETHODCALLTYPE WindowDropTarget::DragEnter(IDataObject* data_obj,
                                                      DWORD key_state,
                                                      POINTL pt,
                                                      DWORD* effect) {
  UINT count = 0;
  has_valid_drop_ = InspectDataObject(data_obj, &count, nullptr);
  if (effect != nullptr) {
    *effect = has_valid_drop_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  }
  if (has_valid_drop_ && on_drag_state_) {
    on_drag_state_(true, count);
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE WindowDropTarget::DragOver(DWORD key_state,
                                                     POINTL pt,
                                                     DWORD* effect) {
  if (effect != nullptr) {
    *effect = has_valid_drop_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE WindowDropTarget::DragLeave() {
  if (has_valid_drop_) {
    has_valid_drop_ = false;
    if (on_drag_state_) {
      on_drag_state_(false, 0);
    }
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE WindowDropTarget::Drop(IDataObject* data_obj,
                                                 DWORD key_state,
                                                 POINTL pt,
                                                 DWORD* effect) {
  const bool was_valid = has_valid_drop_;
  has_valid_drop_ = false;
  if (was_valid && on_drag_state_) {
    on_drag_state_(false, 0);
  }
  UINT count = 0;
  std::wstring first_path;
  if (!InspectDataObject(data_obj, &count, &first_path) || first_path.empty()) {
    if (effect != nullptr) {
      *effect = DROPEFFECT_NONE;
    }
    return S_OK;
  }
  if (effect != nullptr) {
    *effect = DROPEFFECT_COPY;
  }
  if (on_drop_) {
    on_drop_(first_path, count);
  }
  return S_OK;
}
