# Development

## Getting set up

**Linux** (Ubuntu 22.04 or newer, which includes Zorin OS 17):

```bash
sudo apt install python3-gi gir1.2-gtk-4.0 python3-nautilus xvfb
cd linux
python3 -m pytest -m 'not integration'                     # no system changes
xvfb-run -a -s "-screen 0 1280x800x24" python3 -m pytest    # everything
```

**Windows** (10 or 11, PowerShell 5.1):

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path windows\tests -ExcludeTagFilter Integration
.\windows\build\build.ps1        # needs Inno Setup 6
```

There is no cross-compilation and no shared toolchain. Each platform is developed and tested
on itself; CI is what proves the other half still works.

## Running without installing

Both platforms run straight from a clone, which is the fastest way to try a change:

```bash
PYTHONPATH=linux python3 -m tempfileeraser ~/projects --list    # Linux, changes nothing
```

```powershell
.\windows\src\Clear-TempFolders.ps1 -Path C:\projects
```

The Linux `--list` mode exists for exactly this: it exercises the rules, the scanner and the
formatting with no display and no risk.

## The test suites

| Suite | Covers | Needs |
|---|---|---|
| `linux/tests/test_rules.py` | the rule table and matcher | nothing |
| `linux/tests/test_scanner.py` | walking, zones, symlinks, mount boundaries, sizing | nothing |
| `linux/tests/test_remover.py` | trashing and permanent deletion | nothing |
| `linux/tests/test_formatting.py` | every string the user sees | nothing |
| `linux/tests/test_cli.py` | `--list` and argument handling | nothing |
| `linux/tests/test_window.py` | the review window, including a real erase | a display |
| `linux/tests/test_install.py` | `install.sh`, `uninstall.sh`, Thunar merge | marked `integration` |
| `linux/tests/test_build.py` | the tarball and the `.deb` | marked `integration` |
| `windows/tests/*.Tests.ps1` | the same ground in Pester | Pester 5 |

Two conventions keep the suites safe to run on a working machine:

**Nothing touches your real environment.** `test_install.py` points `HOME`, `XDG_DATA_HOME`
and `XDG_CONFIG_HOME` at a temporary directory, and puts stub `nautilus`, `pgrep` and
`dpkg-query` commands first on `PATH` — so your file manager is never restarted and the result
does not depend on what happens to be installed.

**Nothing touches your real Trash.** Trashing is unit-tested by replacing `remover._trash`.
The one test that trashes for real runs in a *subprocess* with its own `HOME`, because GLib
caches the user directories on first use and cannot be redirected in-process.

Mark anything that shells out or writes outside `tmp_path` with `pytest.mark.integration`, so
`-m 'not integration'` stays a safe default.

## Building

```bash
./linux/build.sh                 # tarball + .deb, into dist/
./linux/build.sh --skip-deb      # tarball only
```

```powershell
.\windows\build\build.ps1
.\windows\build\build.ps1 -SkipInstaller
```

Both write to `dist/` at the repository root and take their version from
[VERSION](../VERSION). Four assets make up a release:

| Asset | Edition |
|---|---|
| `TempFileEraserTool-Setup.exe` | Windows, installer |
| `TempFileEraserTool-Script.zip` | Windows, script |
| `temp-file-eraser-tool_<version>_all.deb` | Linux, package |
| `TempFileEraserTool-Linux-Script.tar.gz` | Linux, script |

The Windows asset names carry no version, so the README's
`releases/latest/download/...` links keep working. The `.deb` carries one because Debian
tooling expects it.

## Layout

```
rules/rules.json   detection rules, read by both platforms
docs/              this documentation
windows/           src, script, installer, build, tests   (PowerShell)
linux/             tempfileeraser, integrations, packaging, tests   (Python + GTK 4)
dist/              build output, gitignored
```

Relative paths assume this shape. Within a platform directory the pieces refer to each other
as `..\src`; anything shared is two levels up (`..\..\rules`). `build.ps1` and the Pester
suites name both levels explicitly (`$windows` and `$root`) rather than counting dots.

## CI

[.github/workflows/build.yml](../.github/workflows/build.yml) runs four jobs:

- **version** — fails if a `v*` tag does not match the VERSION file
- **windows** — builds and runs Pester on `windows-latest`
- **linux** — builds and runs pytest under xvfb on **both** `ubuntu-22.04` and `ubuntu-24.04`
- **release** — on a tag only, collects all four assets and publishes them

The Linux matrix is not redundancy. 22.04 and 24.04 ship different generations of
`nautilus-python` with incompatible `MenuProvider` signatures, and the extension supports both
from one file; the matrix is what proves it. Artifacts are uploaded from 22.04 only, since one
copy of each asset is enough.

## Releasing

1. Update [VERSION](../VERSION) — for example `0.0.2`.
2. Commit it.
3. Push a matching tag: `git tag v0.0.2 && git push origin v0.0.2`.

CI publishes the release. If the tag and VERSION disagree it refuses, rather than shipping
assets labelled with the wrong version.

## Things worth knowing before you change them

**The message protocol is load-bearing.** Adding a message type means handling it in the UI
pump on that platform; forgetting to means it is silently dropped. See
[architecture.md](architecture.md).

**`Done` must always be sent, exactly once.** On Linux `jobs.start` guarantees it in a
`finally`; the worker returns a bool for whether it stopped early rather than sending `Done`
itself. Do not send it from a worker.

**Deletion is hand-rolled on purpose.** Neither platform uses `Remove-Item -Recurse` or
`shutil.rmtree`. The hand-written walk is what produces the per-item error list the summary
dialog shows, and what guarantees links are removed as links rather than followed.

**The Nautilus extension runs inside Nautilus.** It must never import the tool or do any
work; it spawns a detached process and returns. A slow extension is a slow file manager.

**Thunar's actions all live in one file.** `integrations/thunar_action.py` merges into
`~/.config/Thunar/uca.xml` by unique id and backs it up first. Never overwrite that file.
