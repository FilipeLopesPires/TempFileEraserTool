; Inno Setup 6 script for the TempFileEraserTool Installer edition.
; Build with: .\build\build.ps1   (passes /DAppVersion and /O<output dir>)

; The real version comes from the VERSION file via build.ps1; this is only a
; fallback for compiling the script directly in the Inno Setup IDE
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "TempFileEraserTool"
#define MenuVerb "Clean up temp and cache folders"
#define MenuIcon "%SystemRoot%\System32\cleanmgr.exe,0"
#define FolderKey "Software\Classes\Directory\shell\TempFileEraserTool"
#define BackgroundKey "Software\Classes\Directory\Background\shell\TempFileEraserTool"

[Setup]
; Never change AppId: upgrades and the Script edition's guard depend on it
AppId={{1B36309B-F347-4709-98CD-45D80C17AB47}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Filipe Lopes Pires
AppPublisherURL=https://github.com/FilipeLopesPires/TempFileEraserTool
AppSupportURL=https://github.com/FilipeLopesPires/TempFileEraserTool/issues
VersionInfoVersion={#AppVersion}
; Per-user install: no UAC prompt, {autopf} becomes %LOCALAPPDATA%\Programs
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
DisableDirPage=yes
MinVersion=10.0.17763
; 64-bit mode stops the 32-bit setup from rewriting System32 paths to SysWOW64
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=TempFileEraserTool-Setup
UninstallDisplayName={#AppName}
UninstallDisplayIcon={sys}\cleanmgr.exe,0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\src\*.ps1"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
; Take over from a Script edition install (the menu keys themselves are overwritten below)
Type: filesandordirs; Name: "{localappdata}\TempFileEraserTool"

[Registry]
; conhost --headless runs PowerShell without a console window flashing on screen
; Right-clicking a folder: Explorer passes the folder as %1
Root: HKCU; Subkey: "{#FolderKey}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "{#FolderKey}"; ValueType: string; ValueName: "MUIVerb"; ValueData: "{#MenuVerb}"
Root: HKCU; Subkey: "{#FolderKey}"; ValueType: expandsz; ValueName: "Icon"; ValueData: "{#MenuIcon}"
Root: HKCU; Subkey: "{#FolderKey}\command"; ValueType: string; ValueName: ""; ValueData: "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ""{app}\Clear-TempFolders.ps1"" -Path ""%1"""
; Right-clicking the empty area inside a folder: Explorer passes the folder as %V
Root: HKCU; Subkey: "{#BackgroundKey}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "{#BackgroundKey}"; ValueType: string; ValueName: "MUIVerb"; ValueData: "{#MenuVerb}"
Root: HKCU; Subkey: "{#BackgroundKey}"; ValueType: expandsz; ValueName: "Icon"; ValueData: "{#MenuIcon}"
Root: HKCU; Subkey: "{#BackgroundKey}\command"; ValueType: string; ValueName: ""; ValueData: "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ""{app}\Clear-TempFolders.ps1"" -Path ""%V"""

[Messages]
FinishedLabel=Setup has installed [name].%n%nRight-click any folder, or an empty area inside one (on Windows 11, choose Show more options first), and pick "Clean up temp and cache folders".
