# Architecture

TempFileEraserTool exists twice: once in PowerShell for Windows, once in Python for Linux.
The two share no code, only [rules/rules.json](../rules/rules.json). They do share a design,
and that design is the thing worth knowing before changing either one.

## The shape of a run

Every run is the same four steps, whichever platform it is on.

```
 file manager  ──▶  entry point  ──▶  background worker  ──▶  review window  ──▶  remover
 right-click        resolve the       walk the tree,          user unchecks       trash or
 a folder           path, refuse      match rules, size       what to keep        erase
                    protected dirs    what matched
```

The worker never touches the UI and the UI never touches the filesystem. They communicate
through a queue of small immutable messages, drained by the UI on a 100 ms timer. That one
decision is what keeps the window responsive while a scan walks a million files, and it is
why the scan can be cancelled at any point: the worker checks a cancel flag between entries.

## The message protocol

Both platforms use the same message types. On Linux they are dataclasses in
[jobs.py](../linux/tempfileeraser/jobs.py); on Windows they are hashtables with a `Type` key,
enqueued in [TempFolderScanner.ps1](../windows/src/TempFolderScanner.ps1).

| Message | Sent when | Carries |
|---|---|---|
| `Progress` | at most ten times a second | text, and `step`/`steps` while erasing |
| `FoundFolder` | a folder matches a rule | id, path, category, confidence, note |
| `FoundFiles` | a folder holds matching files | id, folder path, file names, total bytes |
| `Size` | the sizing pass finishes a folder | id, bytes, file count |
| `Removed` | one item has been dealt with | id, path, success, error, bytes |
| `Failure` | the worker hit something unexpected | message |
| `Done` | always, exactly once, last | whether it stopped early |

Two rules keep this honest. `Done` is always sent, even when the worker throws — on Linux the
wrapper in `jobs.start` guarantees it, so a crash can never leave the window waiting forever.
And the UI drains at most 500 messages per tick, so a burst of matches cannot freeze it.

Ids tie the phases together: a `FoundFolder` row is created when it arrives with its size
still unknown, and the later `Size` message with the same id fills the gap in place. This is
why matches appear immediately while sizes trickle in.

## Scanning, in two phases

Phase one walks the tree and reports matches. **A matched folder is never descended into** —
that is both correct (everything inside `node_modules` goes with it) and what makes the walk
fast, because the heavy trees are exactly the matched ones.

Phase two sizes each match. It is separate because sizing is the expensive part: the first
phase can finish and show you the list while the second is still adding up bytes.

Within a folder, the scanner builds the set of sibling names once and reuses it for every
candidate in that folder. Marker rules (`bin` only next to a `*.csproj`) are answered from
that set rather than by touching the disk again.

## The safety model

The tool deletes things, so the interesting parts are the refusals.

**Protected zones.** Directories holding installed software and per-application state. The
tool refuses to start inside one and skips it when scanning from above.

- Windows: the Windows directory, Program Files, ProgramData, and every user's AppData.
- Linux: `/usr`, `/etc`, `/var`, `/opt`, `/snap`, `/bin`, `/sbin`, `/lib*`, `/boot`, `/proc`,
  `/sys`, `/dev`, `/run`, `/srv`, plus `~/.cache`, `~/.config`, `~/.local/share`,
  `~/.local/state`, `~/.var/app`, `~/snap`, `~/.steam` and `~/.wine`.

**Links are never followed.** Windows skips reparse points (junctions and symlinks); Linux
uses `follow_symlinks=False` everywhere. Nothing outside the scanned folder can be counted or
deleted, and when a link is itself removed only the link goes, never its target.

**Large roots ask first.** A drive root or a home folder can take minutes to scan, so the tool
confirms before starting.

**Version control is skipped.** `.git`, `.hg` and `.svn` are never descended into.

**Uncertain matches start unchecked.** A folder called `build` with no project file beside it
is probably generated, but the tool will not assume so. It is listed, greyed out and
unchecked, and the Type column says why.

Linux adds two refusals Windows does not have. Scans **stay on the filesystem they started
on**, so scanning `$HOME` cannot wander into a mounted NAS or a backup disk. And a generated
folder sitting **directly inside `$HOME`** — `~/.gradle`, `~/.m2` — is treated as a global
tool cache rather than project output, and listed unchecked: it is regenerable, but it costs
a download rather than a rebuild.

## How the two implementations correspond

| Concern | Windows | Linux |
|---|---|---|
| Rules | `src/TempFolderRules.ps1` | `tempfileeraser/rules.py` |
| Scanning and sizing | `src/TempFolderScanner.ps1` | `tempfileeraser/scanner.py` |
| Deletion | `src/TempFolderRemover.ps1` | `tempfileeraser/remover.py` |
| Review window | `src/Clear-TempFolders.ps1` | `tempfileeraser/window.py`, `dialogs.py` |
| Display text | `Format-*` in `Clear-TempFolders.ps1` | `tempfileeraser/formatting.py` |
| Background work | runspace + `ConcurrentQueue` | thread + `SimpleQueue` (`jobs.py`) |
| Row state | `ListViewItem.Tag` | `model.py` `Row`, wrapped by `RowObject` |
| Entry point | `Clear-TempFolders.ps1 -Path` | `tempfileeraser/__main__.py` |
| Menu registration | `HKCU\...\Directory\shell` | `integrations/`, one file per file manager |

Windows carries one burden Linux does not: the `\\?\` prefix, applied by `ConvertTo-LongPath`
to every path before it reaches `System.IO`, because .NET Framework otherwise stops at 260
characters. There is no Linux equivalent and none is needed.

Linux carries one Windows does not: the file manager has to be told the tool exists, per file
manager and per desktop. See [linux/README.md](../linux/README.md).

## Deliberate differences

These are not accidents of porting. They are places where matching Windows would have been
the wrong answer on Linux.

- **Case-sensitive matching**, because ext4 is. It also separates Unity's `Build` from Node's
  `build`, which on Windows can only be told apart by their project markers.
- **Hardlinked files counted once**, using `(st_dev, st_ino)`. The Windows edition lists
  double-counted pnpm stores as a known limitation; Linux does not have it.
- **XDG trash instead of the Recycle Bin**, through `Gio.File.trash()`. Some filesystems have
  no trash folder — FAT and exFAT drives typically — and the tool says so rather than failing
  silently, suggesting Erase permanently instead.
