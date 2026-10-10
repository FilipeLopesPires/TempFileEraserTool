# Installer edition

A standard setup wizard that installs TempFileEraserTool for your account and lists it in
**Settings › Apps › Installed apps**.

## Install

1. Download [TempFileEraserTool-Setup.exe](https://github.com/FilipeLopesPires/TempFileEraserTool/releases/latest/download/TempFileEraserTool-Setup.exe).
2. Run it. There is no administrator prompt. If SmartScreen appears, choose
   **More info › Run anyway** (the installer is not code-signed).

It installs to `%LOCALAPPDATA%\Programs\TempFileEraserTool`. If the Script edition is
installed, setup replaces it.

Silent install: `TempFileEraserTool-Setup.exe /VERYSILENT /SUPPRESSMSGBOXES`

## Uninstall

**Settings › Apps › Installed apps › TempFileEraserTool › Uninstall.**

## Building

Requires [Inno Setup 6](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`).

```powershell
.\build\build.ps1
```

The version comes from the [VERSION](../../VERSION) file. The output is `dist\TempFileEraserTool-Setup.exe` and `dist\TempFileEraserTool-Script.zip`.
The definition is in [TempFileEraserTool.iss](TempFileEraserTool.iss). Never change its
`AppId`.
