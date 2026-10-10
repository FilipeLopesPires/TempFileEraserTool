# Linux edition

Finds regenerable temp, cache and build folders below a folder and erases the ones you pick,
from the file manager's right-click menu. Tested on Zorin OS 17 (GNOME 42 / Nautilus 42) and
built for Ubuntu 22.04 and newer.

Both editions install the same tool. Pick one; they refuse to coexist.

| | **Package edition** | **Script edition** |
|---|---|---|
| Best for | Most people | Anyone who would rather not use `sudo` |
| Install | `sudo apt install ./temp-file-eraser-tool_*.deb` | `./install.sh` |
| Uninstall | `sudo apt remove temp-file-eraser-tool` | `./uninstall.sh` |
| Listed in Software / `apt list --installed` | Yes | No |
| Needs root | Yes, once | No |
| Download | [temp-file-eraser-tool_*.deb](https://github.com/FilipeLopesPires/TempFileEraserTool/releases/latest) | [TempFileEraserTool-Linux-Script.tar.gz](https://github.com/FilipeLopesPires/TempFileEraserTool/releases/latest/download/TempFileEraserTool-Linux-Script.tar.gz) |

## Install

**Package edition**

```bash
sudo apt install ./temp-file-eraser-tool_0.0.1_all.deb
nautilus -q    # only if Nautilus is already running
```

`apt` pulls in everything it needs, including `python3-nautilus` for the top-level menu entry.

**Script edition**

```bash
tar -xzf TempFileEraserTool-Linux-Script.tar.gz
cd TempFileEraserTool-Linux
./install.sh
```

Everything goes under `~/.local`, and the installer says which file managers it registered
with. From a clone of the repository, run `linux/install.sh` instead.

## Using it

- Right-click a folder, or an empty area inside one, and choose **Clean up temp and cache
  folders**.
- The list fills in while the scan runs, and sizes appear as they are calculated. **Erase**
  becomes available once the scan finishes. **Stop scan** ends it early and keeps what was
  found so far.
- Every item starts checked, except the ones marked *no project file found*, *possible temp
  file* or *global tool cache*. Those start unchecked and greyed out.
- **Select all** checks or unchecks everything. Click a column header to sort, for example by
  size. Right-click a row to open it in your file manager.
- Temp files are grouped per folder: one row lists the matching files in that folder. Erasing
  that row deletes only those files, never the folder itself.
- **Move to Trash** lets you restore items, but the space is only freed once the Trash is
  emptied. **Erase permanently** asks for confirmation first.

There is also a listing mode that changes nothing:

```bash
temp-file-eraser ~/projects --list
```

## File manager support

| File manager | Where the entry appears | Needs |
|---|---|---|
| Nautilus (GNOME, Zorin Core) | Top level of the right-click menu | `python3-nautilus` |
| Nautilus without that package | Under the **Scripts** submenu | nothing |
| Nemo (Cinnamon) | Right-click menu | nothing |
| Thunar (XFCE, Zorin Lite) | Right-click menu | nothing |
| Dolphin (KDE) | Right-click menu | nothing |
| Anything else | **Open With → Temp File Eraser** on a folder | nothing |

The installer registers only the file managers it actually finds. Nautilus has to be
restarted once (`nautilus -q`) before a new entry shows up.

## How it differs from the Windows edition

The detection rules are shared, in [rules.json](../rules/rules.json). The behaviour differs
where Linux differs:

- **Matching is case-sensitive**, because ext4 is. This is also what tells Unity's `Build`
  apart from Node's `build`, which on Windows can only be separated by their project markers.
- **The scan stays on one filesystem.** Scanning `$HOME` will not walk into a mounted NAS or
  a backup disk.
- **Hardlinked files are counted once**, so a pnpm store reports the space it actually
  occupies. The Windows edition lists this as a known limitation.
- **A generated folder directly inside `$HOME`** (`~/.gradle`, `~/.m2` and the like) is listed
  as a global tool cache and starts unchecked: it is regenerable, but it costs a download
  rather than a rebuild.
- **The Recycle Bin becomes the XDG trash.** Some filesystems have no trash folder, typically
  FAT or exFAT drives; the tool says so and suggests erasing permanently instead.
- **No 260-character path limit**, so none of the Windows long-path handling is needed.

Never touched: `/usr`, `/etc`, `/var`, `/opt`, `/snap` and the rest of the system; `~/.cache`,
`~/.config`, `~/.local/share`, `~/.local/state`, `~/.var/app`, `~/snap`, `~/.steam` and
`~/.wine`; `.git`, `.hg` and `.svn`; symlinks, which are never followed; and backup files
(`*.bak`, `*.orig`, `*~`) and `.directory`.

## Development

```bash
sudo apt install python3-gi gir1.2-gtk-4.0 python3-nautilus xvfb
python3 -m pytest -m 'not integration'                      # no system changes
xvfb-run -a -s "-screen 0 1280x800x24" python3 -m pytest     # everything
./build.sh                                                   # both release assets
./build.sh --skip-deb                                        # tarball only
```

The GUI tests need a display; `xvfb-run` provides one. The integration tests run `install.sh`
and `uninstall.sh` against a throwaway `HOME`, and the one test that really uses the trash
does so in a subprocess with its own `HOME`, so your own Trash is never touched.

Layout:

- `tempfileeraser/rules.py` — what counts as temp, loaded from `rules.json`
- `tempfileeraser/scanner.py` — scanning and sizing in a background thread
- `tempfileeraser/remover.py` — trashing and permanent deletion
- `tempfileeraser/window.py`, `dialogs.py` — the review window
- `tempfileeraser/__main__.py` — entry point and `--list`
- `integrations/` — one file per file manager
- `packaging/` — the `.deb` control files and the `/usr/bin` launcher
