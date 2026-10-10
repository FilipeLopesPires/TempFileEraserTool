# Script edition

Two PowerShell scripts. There is no setup program and nothing is listed in Installed apps.

## Install

1. Download [TempFileEraserTool-Script.zip](https://github.com/FilipeLopesPires/TempFileEraserTool/releases/latest/download/TempFileEraserTool-Script.zip) and extract it.
2. In that folder, run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

From a clone of the repository, run `.\script\install.ps1` instead.

The tool is copied to `%LOCALAPPDATA%\TempFileEraserTool` and the menu entries are registered
for your account only.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

This removes the menu entries and the tool files.

If the Installer edition is installed, both scripts refuse to run. Use Settings › Apps to
manage it.
