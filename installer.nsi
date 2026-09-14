; Whisper Subtitler - NSIS installer
;
; Build (Debian):
;   NSISDIR=<path-to-nsis-data> PATH=<bin>:$PATH makensis installer.nsi
;
; Produces: WhisperSubtitler_Setup.exe

Unicode true
SetCompressor /SOLID lzma

!define APP_NAME "Whisper Subtitler"
!define APP_VERSION "1.0"
; The launcher binary is built as WhisperSubtitler.exe (no space) by
; build_package.sh. APP_NAME (display name, with space) must NOT be reused
; for the file name or every shortcut would point to a missing file.
!define APP_FILE "WhisperSubtitler.exe"
!define APP_ICON "assets\WhisperSubtitler.ico"
!define REG_UNINSTALL "Software\Microsoft\Windows\CurrentVersion\Uninstall\WhisperSubtitler"

Name "${APP_NAME}"
OutFile "WhisperSubtitler_Setup.exe"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\${APP_NAME}"
ShowInstDetails nevershow
ShowUninstDetails nevershow

!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "assets\header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "assets\welcome.bmp"

!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_FILE}"
!define MUI_FINISHPAGE_RUN_CHECKED
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${APP_NAME}"

; extra note on the Welcome page explaining the one-time internet requirement
!define MUI_WELCOMEPAGE_TITLE "Welcome to ${APP_NAME}"
!define MUI_WELCOMEPAGE_TEXT "This program creates subtitle files (.srt) from your videos, right on your own computer.$\r$\n$\r$\nOn the first use an internet connection is required to download the speech recognition model.$\r$\n$\r$\nPress Next to continue."

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "Install" SEC_INSTALL
    SetOutPath "$INSTDIR"
    File /r "dist\WhisperSubtitler\*.*"

    WriteUninstaller "$INSTDIR\Uninstall.exe"

    ; Always install shortcuts into the CURRENT user's environment.
    ; On real Windows, without this they silently fall back to the
    ; "All Users" locations, which are not writable without admin rights.
    SetShellVarContext current

    CreateDirectory "$SMPROGRAMS\${APP_NAME}"
    CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_FILE}"
    CreateShortCut "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk" "$INSTDIR\Uninstall.exe"
    CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_FILE}"

    ; Diagnostics: list what is actually on disk and check every critical file.
    Call CheckInstall
SectionEnd

Section "Uninstall"
    Delete "$DESKTOP\${APP_NAME}.lnk"
    Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
    Delete "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk"
    RMDir "$SMPROGRAMS\${APP_NAME}"

    DeleteRegKey HKCU "${REG_UNINSTALL}"

    RMDir /r "$INSTDIR"
SectionEnd

; Diagnose the install: write install_check.txt with what is on disk and
; warn about any critical file that is missing (e.g. silently removed by an
; antivirus during extraction).
Function CheckInstall
    FileOpen $4 "$INSTDIR\install_check.txt" w
    FileWrite $4 "Whisper Subtitler - installation check$\r$\n"

    ; Top-level entries
    FileWrite $4 "Folder contents:$\r$\n"
    FindFirst $0 $1 "$INSTDIR\*"
top_loop:
    StrCmp $1 "" top_done
    FileWrite $4 "  $1$\r$\n"
    FindNext $0 $1
    Goto top_loop
top_done:
    FindClose $0
    FileWrite $4 "$\r$\n"

    ; Critical files
    IfFileExists "$INSTDIR\${APP_FILE}" 0 l_missing
    FileWrite $4 "[OK] launcher present$\r$\n"
    Goto l_next
l_missing:
    FileWrite $4 "[MISSING] $INSTDIR\${APP_FILE}$\r$\n"
l_next:

    IfFileExists "$INSTDIR\python\pythonw.exe" 0 l_missing2
    FileWrite $4 "[OK] pythonw present$\r$\n"
    Goto l_next2
l_missing2:
    FileWrite $4 "[MISSING] $INSTDIR\python\pythonw.exe$\r$\n"
l_next2:

    IfFileExists "$INSTDIR\python\python311.dll" 0 l_missing3
    FileWrite $4 "[OK] python311.dll present$\r$\n"
    Goto l_next3
l_missing3:
    FileWrite $4 "[MISSING] $INSTDIR\python\python311.dll$\r$\n"
l_next3:

    IfFileExists "$INSTDIR\ffmpeg\ffmpeg.exe" 0 l_missing4
    FileWrite $4 "[OK] ffmpeg present$\r$\n"
    Goto l_next4
l_missing4:
    FileWrite $4 "[MISSING] $INSTDIR\ffmpeg\ffmpeg.exe$\r$\n"
l_next4:

    FileClose $4

    ; Never block a silent (/S) install with dialogs.
    IfSilent 0 l_visible
    Goto l_done
l_visible:
    IfFileExists "$INSTDIR\${APP_FILE}" 0 l_fail
    MessageBox MB_OK|MB_ICONINFORMATION "Installation completed. File summary written to:$\r$\n$INSTDIR\install_check.txt"
    Goto l_done
l_fail:
    MessageBox MB_OK|MB_ICONEXCLAMATION "Warning: the main program file was not found.$\r$\n$\r$\nAn antivirus may have blocked the program during installation.$\r$\nCheck the report file:$\r$\n$INSTDIR\install_check.txt"
l_done:
FunctionEnd