#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <string>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kWindowTitle[] = L"Erebrus Drop";
constexpr wchar_t kUrlSchemeKey[] =
    L"Software\\Classes\\erebrusdrop";

bool SetRegistryString(HKEY key, const wchar_t* name,
                       const std::wstring& value) {
  return ::RegSetValueExW(
             key, name, 0, REG_SZ,
             reinterpret_cast<const BYTE*>(value.c_str()),
             static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) ==
         ERROR_SUCCESS;
}

// Register the callback protocol for the current user. This requires no admin
// access and makes browser redirects such as erebrusdrop://auth?... launch the
// installed executable.
bool RegisterUrlScheme() {
  wchar_t executable_path[MAX_PATH];
  const DWORD path_length =
      ::GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
  if (path_length == 0 || path_length == MAX_PATH) {
    return false;
  }

  HKEY scheme_key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kUrlSchemeKey, 0, nullptr, 0,
                        KEY_WRITE, nullptr, &scheme_key, nullptr) !=
      ERROR_SUCCESS) {
    return false;
  }

  const bool scheme_saved =
      SetRegistryString(scheme_key, nullptr,
                        L"URL:Erebrus Drop authentication callback") &&
      SetRegistryString(scheme_key, L"URL Protocol", L"");
  ::RegCloseKey(scheme_key);

  HKEY command_key = nullptr;
  const std::wstring command_key_path =
      std::wstring(kUrlSchemeKey) + L"\\shell\\open\\command";
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, command_key_path.c_str(), 0,
                        nullptr, 0, KEY_WRITE, nullptr, &command_key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }

  const std::wstring command =
      L"\"" + std::wstring(executable_path, path_length) + L"\" \"%1\"";
  const bool command_saved = SetRegistryString(command_key, nullptr, command);
  ::RegCloseKey(command_key);
  return scheme_saved && command_saved;
}

// A browser callback starts a second process. Forward its URL to the existing
// Flutter window and focus that window instead of opening another instance.
bool SendAppLinkToRunningInstance() {
  HWND window =
      ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", kWindowTitle);
  if (window == nullptr) {
    return false;
  }

  SendAppLink(window);

  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                 SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
  ::SetForegroundWindow(window);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  RegisterUrlScheme();
  if (SendAppLinkToRunningInstance()) {
    return EXIT_SUCCESS;
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(880, 820);
  if (!window.Create(kWindowTitle, origin, size)) {
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
