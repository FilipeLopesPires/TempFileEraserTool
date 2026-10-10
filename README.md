# TempFileEraserTool

Find and erase regenerable temp, cache and build folders with one right-click.

Right-click a folder, or an empty area inside one, and choose **Clean up temp and cache
folders**. The tool searches every subfolder for things your tools can rebuild, such as
`node_modules`, Unity's `Library`, Unreal's `Intermediate`, `__pycache__`, `bin`/`obj` and
stray temp files. It then lists them for review, with the full path and size of each one.

Uncheck anything you want to keep, choose **Move to Recycle Bin** (**Trash** on Linux) or
**Erase permanently**, and press **Erase**. A summary tells you how much space was recovered.

Runs on **Windows 10/11** and on **Linux** (ZorinOS, Ubuntu 22.04 and newer). Both platforms
share one detection rule table, [rules.json](rules/rules.json).

## Linux

See **[linux/](linux/README.md)** for the package (`.deb`) and script editions, which file
managers are supported, and the handful of places the Linux behaviour deliberately differs
from Windows.

```bash
sudo apt install ./temp-file-eraser-tool_0.0.1_all.deb   # or: ./install.sh
```

## Windows: choose your edition

Both editions install the same tool, and neither needs administrator rights.

| | **Installer edition** | **Script edition** |
|---|---|---|
| Best for | Most people | Developers comfortable with PowerShell |
| Install | Run a setup wizard | Run `install.ps1` |
| Uninstall | Settings › Apps | Run `uninstall.ps1` |
| Listed in Installed apps | Yes | No |
| Download | [TempFileEraserTool-Setup.exe](https://github.com/FilipeLopesPires/TempFileEraserTool/releases/latest/download/TempFileEraserTool-Setup.exe) | [TempFileEraserTool-Script.zip](https://github.com/FilipeLopesPires/TempFileEraserTool/releases/latest/download/TempFileEraserTool-Script.zip) |
| Details | [windows/installer/](windows/installer/README.md) | [windows/script/](windows/script/README.md) |

Install only one edition at a time. The Installer edition replaces the Script edition if it
finds it.

> **Windows SmartScreen:** the setup program is not code-signed, so Windows may say
> "Windows protected your PC" the first time you run it. Choose **More info › Run anyway**.

## Using it (Windows)

- On Windows 11 the entry is in the classic menu: choose **Show more options** first, or
  press Shift+Right-click.
- The list fills in while the scan runs, and sizes appear as they are calculated. **Erase**
  becomes available once the scan finishes. **Stop scan** ends it early and keeps what was
  found so far.
- Every item starts checked, except the ones marked *no project file found* or
  *possible temp file*. Those start unchecked and greyed out (see below).
- **Select all** above the list checks or unchecks everything. Click a column header to
  sort, for example by size. Right-click a row to open it in Explorer.
- Temp files are grouped per folder: one row lists the matching files in that folder.
  Erasing that row deletes only those files, never the folder itself.
- **Move to Recycle Bin** lets you restore items, but the space is only freed once the
  Recycle Bin is emptied. **Erase permanently** asks for confirmation first.

## What gets detected

The tool only lists things that a build, an install or the editor recreates on its own.

- **Anywhere:**
  - `node_modules`, `.next`, `.nuxt`, `.svelte-kit`, `.parcel-cache`, `.turbo`, `.angular`
  - `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `*.egg-info`
  - Python virtual environments, recognised by their `pyvenv.cfg` file
  - `.gradle`, `CMakeFiles`, `.dart_tool`, `.terraform`, `.vs`, `.idea`, and more
- **Only inside a recognised project.** Folder names like `build` or `Library` are too
  common to delete on sight, so a project file must sit next to them:
  - **Unity:** `Library`, `Temp`, `Obj`, `Logs` and `Build(s)`, next to `Assets` and
    `ProjectSettings`
  - **Unreal:** `Binaries`, `Intermediate`, `Saved` and `DerivedDataCache`, next to a
    `.uproject` or `.uplugin` file
  - **Godot:** `.godot` and `.import`
  - **.NET:** `bin` and `obj`, next to a `.csproj` or `.sln` file
  - **Node.js:** `dist`, `build`, `out` and `coverage`, next to `package.json`
  - **Java, Rust, CMake, Flutter, Elixir, PHP, Zig, Swift, CocoaPods and Jekyll:** their
    build and dependency folders
- **Temp files:**
  - `Thumbs.db`, `.DS_Store`, Office `~$` lock files, `*.tmp`, editor swap files
  - stray `*.pyc` files, `*.tsbuildinfo`, `.eslintcache`
  - `npm-debug.log` and similar debug logs, crash dumps (`*.dmp`)
  - the `.sln` and `.csproj` files Unity regenerates
- **Listed unchecked:**
  - `bin`, `obj`, `build`, `dist`, `out`, `target`, `Temp` and `Intermediate` with no project
    file next to them
  - plain `*.log` files

  They are probably generated, but check them first.

Never touched:
- `desktop.ini`, `.directory`, backups (`*.bak`, `*.orig`, `*~`) and `.git` folders.
- On Windows: anything under Windows, Program Files, ProgramData or any user's AppData.
  On Linux: `/usr`, `/etc`, `/var`, `/opt`, `/snap` and the rest of the system, plus
  `~/.cache`, `~/.config`, `~/.local/share`, `~/.var/app` and `~/snap`. These hold installed
  apps, and their folders are not yours to rebuild. The tool refuses to start inside them and
  skips them when scanning from above. Scanning a whole drive or your home folder asks for
  confirmation first.
- Junctions and symbolic links. They are never followed, so nothing outside the scanned
  folder is counted or deleted.

## What's next

See the [roadmap](ROADMAP.md): your own detection rules, and a place at the top of the
Windows 11 menu. On Linux the entry is already at the top level.

## Development

```
rules/rules.json   detection rules, read by both platforms
docs/              architecture, detection rules, development
windows/           src, script, installer, build, tests  (PowerShell)
linux/             tempfileeraser, integrations, packaging, tests  (Python + GTK 4)
dist/              build output for both
```

- [docs/architecture.md](docs/architecture.md) — how a run works, the message protocol
  between the scanner and the window, and the safety model behind every refusal
- [docs/detection-rules.md](docs/detection-rules.md) — the `rules.json` format and how to add
  a rule
- [docs/development.md](docs/development.md) — setup, the test suites, building and releasing

Windows:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path windows\tests -ExcludeTagFilter Integration   # safe: no system changes
.\windows\build\build.ps1                                        # needs Inno Setup 6
```

Linux (see [linux/README.md](linux/README.md) for more):

```bash
cd linux
python3 -m pytest -m 'not integration'                     # safe: no system changes
xvfb-run -a -s "-screen 0 1280x800x24" python3 -m pytest    # everything
./build.sh
```

The integration tests install and uninstall the real tool: on Windows for the current user,
on Linux against a throwaway `HOME`. CI runs both on every push.

The Windows worker is split into four scripts in [windows/src/](windows/src/):
- `Clear-TempFolders.ps1`: entry point and review window
- `TempFolderRules.ps1`: what counts as temp
- `TempFolderScanner.ps1`: scanning and sizing in the background
- `TempFolderRemover.ps1`: deletion

The Linux port mirrors that split in [linux/tempfileeraser/](linux/README.md).

Both read the same detection rules from [rules/rules.json](rules/rules.json), so a new rule
only has to be written once. Adding one there is usually all a new tool or framework needs.

To release, update the [VERSION](VERSION) file (for example `0.0.2`), then push a matching
tag (`v0.0.2`). CI publishes a release with all four downloads, and refuses to if the tag and
the VERSION file disagree.

## License

[MIT](LICENSE.md) © 2026 Filipe Lopes Pires
