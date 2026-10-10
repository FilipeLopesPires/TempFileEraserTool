# Roadmap

TempFileEraserTool finds regenerable temp, cache and build folders below a folder and erases
the ones you pick. Like its sibling, FontInstallerTool, it is planned as a set of editions
("tiers") that share one core. Each tier adds a better way to install the tool or a smarter
menu entry.

| Tier | Edition | For | Status |
|------|---------|-----|--------|
| 1 | Script edition | Developers who are comfortable with PowerShell | Available |
| 2 | Installer edition | Anyone who wants a normal setup wizard and an uninstall entry | Available |
| 3 | Custom rules | Users who want to add or switch off detection rules | Idea |
| 4 | Modern menu | Users who want the entry at the top of the Windows 11 menu | Idea |

Tiers 1 and 2 need no administrator rights.

The Linux edition has its own two tiers, both available: a script edition (`install.sh`, no
root) and a package edition (`.deb`, listed in Software). See
[linux/README.md](linux/README.md).

## Tier 1: Script edition (available)

Two PowerShell scripts, `install.ps1` and `uninstall.ps1`, copy the worker scripts into your
user profile and register two context menu entries: one on folders, one on the empty area
inside a folder.

- The entries are in the classic context menu. On Windows 11 they are under
  **Show more options**, or press Shift+Right-click.
- No code signing is needed and nothing needs compiling.

## Tier 2: Installer edition (available)

The same tool, delivered as a standard Windows setup program built with Inno Setup.

- It shows up in **Settings › Apps › Installed apps** and can be uninstalled from there.
- It installs per-user, so there is no administrator (UAC) prompt.
- It takes over from a Tier 1 installation if it finds one, so you never get two menu
  entries.
- The installer is not code-signed. The first time you run it, Windows SmartScreen may show
  "Windows protected your PC". Choose **More info › Run anyway**. That is a warning, not a
  block.
- Next: publish it through `winget` and Scoop, which accept unsigned installers.

## Tier 3: Custom rules (idea)

The detection rules are already data, in [rules/rules.json](rules/rules.json), read by both
platforms. A user rules file would make them adjustable without editing the tool:

- add folder or file names, with or without a project marker next to them;
- switch off a built-in rule, for example to keep `.idea` folders;
- exclude specific paths from every scan.

A command-line listing mode (`-WhatIf`) would fit here too, for use in scripts. The Linux
edition already has one: `temp-file-eraser PATH --list`.

## Tier 4: Modern menu (idea)

The entry appears at the top level of the Windows 11 context menu, with no need for
**Show more options**. As described in FontInstallerTool's roadmap, this needs:

- an `IExplorerCommand` shell extension (a small C++ DLL);
- an MSIX package with identity, signed through the Microsoft Store or Azure Trusted Signing.

This tier has no Linux equivalent: the Nautilus extension is already at the top level of the
menu, with no submenu to open first.

## Known limitations (all tiers)

- If your organisation enforces a PowerShell execution policy through Group Policy, the menu
  command may be blocked. (Windows)
- The Recycle Bin has a size limit. When a folder is too big for it, Windows asks whether to
  delete it permanently instead. Paths longer than 260 characters cannot go to the Recycle
  Bin; use **Erase permanently** for those. (Windows)
- Not every filesystem has a trash folder, typically FAT and exFAT drives. The tool says so
  and suggests erasing permanently instead. (Linux)
- Files that a running program keeps open (an IDE, a dev server, Unity or Unreal) cannot be
  removed on Windows. They are listed as failures in the summary. Close the program and run
  the tool again.
- On Windows, sizes count every file once. Hard links, which pnpm uses for its package store,
  can make the space actually freed smaller than shown. The Linux edition counts hardlinked
  files once and does not have this problem.
