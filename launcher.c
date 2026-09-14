/*
 * Whisper Subtitler - Windows launcher.
 *
 * Launches the Python GUI (whisper_gui.pyw) using the bundled
 * embedded Python runtime. No console window is shown.
 *
 * Build (Debian, mingw-w64):
 *   x86_64-w64-mingw32-gcc -O2 -mwindows -o WhisperSubtitler.exe launcher.c -lshlwapi
 */

#include <windows.h>
#include <shlwapi.h>
#include <wchar.h>

static void show_error(const wchar_t *message)
{
    MessageBoxW(NULL, message, L"Whisper Subtitler", MB_OK | MB_ICONERROR);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
                   LPSTR lpCmdLine, int nCmdShow)
{
    (void)hInstance;
    (void)hPrevInstance;
    (void)lpCmdLine;
    (void)nCmdShow;

    wchar_t exe_path[MAX_PATH];
    if (!GetModuleFileNameW(NULL, exe_path, MAX_PATH)) {
        show_error(L"Unable to determine the application folder.");
        return 1;
    }

    wchar_t app_dir[MAX_PATH];
    wcscpy(app_dir, exe_path);
    PathRemoveFileSpecW(app_dir);

    /* Where the bundled Python lives */
    wchar_t pythonw_path[MAX_PATH];
    swprintf(pythonw_path, MAX_PATH, L"%ls\\python\\pythonw.exe", app_dir);
    if (GetFileAttributesW(pythonw_path) == INVALID_FILE_ATTRIBUTES) {
        show_error(L"Python is missing. The application folder may be corrupted.\n\n"
                   L"Extract the whole folder and run WhisperSubtitler.exe again.");
        return 1;
    }

    /* The GUI script */
    wchar_t script_path[MAX_PATH];
    swprintf(script_path, MAX_PATH, L"%ls\\whisper_gui.pyw", app_dir);
    if (GetFileAttributesW(script_path) == INVALID_FILE_ATTRIBUTES) {
        show_error(L"The main program file is missing. The application folder may be corrupted.");
        return 1;
    }

    /* Prepend the bundled ffmpeg folder to PATH so child processes can use it */
    wchar_t ffmpeg_dir[MAX_PATH];
    swprintf(ffmpeg_dir, MAX_PATH, L"%ls\\ffmpeg", app_dir);

    wchar_t old_path[8192];
    DWORD old_len = GetEnvironmentVariableW(L"PATH", old_path, 8192);
    wchar_t new_path[9000];
    if (old_len > 0) {
        swprintf(new_path, 9000, L"%ls;%ls", ffmpeg_dir, old_path);
    } else {
        swprintf(new_path, 9000, L"%ls", ffmpeg_dir);
    }
    SetEnvironmentVariableW(L"PATH", new_path);

    /* Point Tcl/Tk at the bundled script libraries regardless of install path.
       They live inside the embedded Python folder (python/tcl/...). */
    wchar_t python_dir[MAX_PATH];
    swprintf(python_dir, MAX_PATH, L"%ls\\python", app_dir);

    wchar_t tcl_library[MAX_PATH];
    wchar_t tk_library[MAX_PATH];
    swprintf(tcl_library, MAX_PATH, L"%ls\\tcl\\tcl8.6", python_dir);
    swprintf(tk_library, MAX_PATH, L"%ls\\tcl\\tk8.6", python_dir);
    SetEnvironmentVariableW(L"TCL_LIBRARY", tcl_library);
    SetEnvironmentVariableW(L"TK_LIBRARY", tk_library);

    /* Work from the application folder so relative paths resolve */
    SetCurrentDirectoryW(app_dir);

    wchar_t cmdline[7000];
    swprintf(cmdline, 7000, L"\"%ls\" \"%ls\"", pythonw_path, script_path);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessW(pythonw_path, cmdline, NULL, NULL, FALSE, 0, NULL, app_dir, &si, &pi)) {
        show_error(L"Unable to start the application.");
        return 1;
    }

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}