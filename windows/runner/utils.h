#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// Resolves relative command-line file arguments against the current
// working directory, replacing existing relative file paths with their
// absolute form. Arguments that look like flags (leading '-' or '/'), or
// that don't resolve to an existing file, are returned unchanged. Call
// BEFORE any SetCurrentDirectory so relative paths keep the meaning they
// had at launch.
std::vector<std::string> ResolveRelativeFileArguments(
    std::vector<std::string> arguments);

#endif  // RUNNER_UTILS_H_
