#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

namespace {

// Converts a UTF-8 string to UTF-16. Returns an empty string on failure.
std::wstring Utf16FromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return std::wstring();
  }
  // -1: the input is null-terminated, so the returned size includes the
  // terminator.
  int target_length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                            utf8_string.c_str(), -1, nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }
  std::wstring utf16_string(static_cast<size_t>(target_length), L'\0');
  int written = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      utf8_string.c_str(), -1,
                                      utf16_string.data(), target_length);
  if (written <= 0) {
    return std::wstring();
  }
  // Drop the embedded null terminator the -1 form wrote.
  utf16_string.resize(static_cast<size_t>(written) - 1);
  return utf16_string;
}

}  // namespace

std::vector<std::string> ResolveRelativeFileArguments(
    std::vector<std::string> arguments) {
  for (std::string& arg : arguments) {
    // Flags are never file paths.
    if (arg.empty() || arg[0] == '-' || arg[0] == '/') {
      continue;
    }
    std::wstring wide = Utf16FromUtf8(arg);
    if (wide.empty()) {
      continue;
    }
    // GetFullPathNameW resolves against the CURRENT directory, so the
    // caller must run this before any SetCurrentDirectory.
    DWORD needed = ::GetFullPathNameW(wide.c_str(), 0, nullptr, nullptr);
    if (needed == 0) {
      continue;
    }
    std::wstring absolute(needed, L'\0');
    DWORD written =
        ::GetFullPathNameW(wide.c_str(), needed, absolute.data(), nullptr);
    if (written == 0 || written >= needed) {
      continue;
    }
    absolute.resize(written);
    // Only rewrite arguments that point at an existing file or directory:
    // a relative argument that doesn't exist is probably a flag value or a
    // future output path, and absolutizing it could change its meaning.
    if (::GetFileAttributesW(absolute.c_str()) == INVALID_FILE_ATTRIBUTES) {
      continue;
    }
    std::string utf8 = Utf8FromUtf16(absolute.c_str());
    if (!utf8.empty()) {
      arg = std::move(utf8);
    }
  }
  return arguments;
}
