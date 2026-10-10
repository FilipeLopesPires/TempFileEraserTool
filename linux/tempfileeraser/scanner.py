r"""Walks a folder tree, reports regenerable folders and temp files, then sizes them.

Ported from src/TempFolderScanner.ps1. Differences from the Windows edition, all
of them because Linux is not Windows:

  - No \\?\ long-path dance: PATH_MAX is 4096 and nothing special is needed.
  - Symlinks are never followed, counted or descended into. Linux has no junctions.
  - The scan stays on the filesystem it started on, so scanning $HOME does not walk
    into a mounted NAS or a backup disk.
  - Sizes count a hardlinked file once, which the Windows edition cannot do. That is
    what makes a pnpm store report the space it actually occupies.
  - A generated folder sitting directly in $HOME (~/.gradle and friends) is a global
    tool cache, not project output, so it is listed unchecked.
"""

from __future__ import annotations

import functools
import os
import time
from pathlib import Path
from typing import Iterable, Sequence

from . import jobs
from .jobs import FoundFiles, FoundFolder, Job, Progress, Size
from .rules import CERTAIN, FILE, FOLDER, Match, RuleSet, SiblingSet, UNCERTAIN, default_ruleset

# Never descended into, wherever they appear
SKIPPED_FOLDER_NAMES = frozenset({'.git', '.hg', '.svn', 'lost+found'})

# Installed software and per-application state live here; their node_modules, bin or
# cache folders are not the user's to regenerate
SYSTEM_ZONES = ('/bin', '/sbin', '/lib', '/lib32', '/lib64', '/libx32', '/usr', '/etc',
                '/var', '/boot', '/opt', '/snap', '/proc', '/sys', '/dev', '/run', '/srv',
                '/lost+found')
HOME_ZONES = ('.cache', '.config', '.local/share', '.local/state', '.var/app', 'snap',
              '.steam', '.wine')

GLOBAL_CACHE_NOTE = 'global tool cache, not project output'
PROGRESS_INTERVAL = 0.1


def protected_zones(home: Path | None = None) -> tuple[Path, ...]:
    home = Path(home) if home else Path.home()
    return tuple([Path(zone) for zone in SYSTEM_ZONES] + [home / zone for zone in HOME_ZONES])


def find_protected_zone(path: Path, zones: Sequence[Path]) -> Path | None:
    """The zone that contains path, or is path, else None."""
    for zone in zones:
        if path == zone or path.is_relative_to(zone):
            return zone
    return None


def is_large_scan_root(path: Path, home: Path | None = None) -> bool:
    """Roots that hold so much that a scan can take minutes."""
    home = Path(home) if home else Path.home()
    return path in (home, Path('/home'), Path('/')) or os.path.ismount(path)


def resolve_scan_root(raw: str) -> Path:
    path = Path(raw.strip()).expanduser()
    if not path.is_dir():
        raise ValueError(f'Folder not found: {path}')
    return path.resolve()


def folder_size(path: str | Path, cancel) -> Size | None:
    """Bytes and file count below path, or None when cancelled.

    Symlinks are not followed, and a file with more than one link is counted once:
    pnpm's store and Nix-style layouts are full of hardlinks that would otherwise
    be reported several times over.
    """
    total = 0
    files = 0
    seen: set[tuple[int, int]] = set()
    pending = [str(path)]
    while pending:
        if cancel.is_set():
            return None
        try:
            with os.scandir(pending.pop()) as entries:
                listing = list(entries)
        except OSError:
            continue  # vanished or unreadable: skip it, keep going
        for entry in listing:
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    pending.append(entry.path)
                    continue
                info = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if info.st_nlink > 1:
                key = (info.st_dev, info.st_ino)
                if key in seen:
                    continue
                seen.add(key)
            total += info.st_size
            files += 1
    return Size(id=-1, bytes=total, files=files)


def entry_device(entry: os.DirEntry) -> int | None:
    """The filesystem a directory entry lives on, or None if it cannot be read."""
    try:
        return entry.stat(follow_symlinks=False).st_dev
    except OSError:
        return None


def _as_global_cache(match: Match) -> Match:
    return Match(match.category, UNCERTAIN, GLOBAL_CACHE_NOTE)


def _file_groups(entries: Iterable[os.DirEntry], siblings: SiblingSet,
                 ruleset: RuleSet) -> dict[str, dict]:
    groups: dict[str, dict] = {}
    for entry in entries:
        match = ruleset.match(FILE, entry.name, siblings)
        if match is None:
            continue
        try:
            size = entry.stat(follow_symlinks=False).st_size
        except OSError:
            size = 0
        group = groups.setdefault(match.confidence, {'files': [], 'bytes': 0, 'categories': []})
        group['files'].append(entry.name)
        group['bytes'] += size
        if match.category not in group['categories']:
            group['categories'].append(match.category)
    return groups


def scan(root: str | Path, message_queue, cancel, *, zones: Sequence[Path] | None = None,
         ruleset: RuleSet | None = None, home: Path | None = None) -> bool:
    """Scans everything below root (never root itself) and reports through message_queue.

    Returns True if it stopped early. Matched folders are not descended into, which
    also keeps the walk fast because the heavy trees are the matched ones.
    """
    root = Path(root)
    zones = protected_zones(home) if zones is None else tuple(zones)
    ruleset = ruleset or default_ruleset()
    home = Path(home) if home else Path.home()
    try:
        root_device = root.stat().st_dev
    except OSError:
        root_device = None

    found: list[FoundFolder] = []
    next_id = 0
    last_progress = 0.0
    pending = [str(root)]

    # Phase 1: find matches
    while pending:
        if cancel.is_set():
            return True
        directory = pending.pop()
        now = time.monotonic()
        if now - last_progress >= PROGRESS_INTERVAL:
            message_queue.put(Progress(f'Scanning {directory}'))
            last_progress = now

        try:
            with os.scandir(directory) as scanned:
                entries = sorted(scanned, key=lambda entry: entry.name)
        except OSError:
            continue  # permission denied or vanished: skip this folder, keep scanning

        siblings = SiblingSet(entry.name for entry in entries)
        in_home = Path(directory) == home
        subfolders: list[str] = []
        files: list[os.DirEntry] = []

        for entry in entries:
            try:
                if entry.is_symlink():
                    continue
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                continue

            if not is_dir:
                files.append(entry)
                continue
            if entry.name in SKIPPED_FOLDER_NAMES or entry.name.startswith('.Trash-'):
                continue
            if find_protected_zone(Path(entry.path), zones):
                continue
            if root_device is not None and entry_device(entry) != root_device:
                continue  # a different filesystem is mounted here

            match = ruleset.match(FOLDER, entry.name, siblings, entry.path)
            if match is None:
                subfolders.append(entry.path)
                continue
            if in_home:
                match = _as_global_cache(match)
            item = FoundFolder(id=next_id, path=entry.path, category=match.category,
                               confidence=match.confidence, note=match.note)
            next_id += 1
            found.append(item)
            message_queue.put(item)

        groups = _file_groups(files, siblings, ruleset) if files else {}
        for confidence in (CERTAIN, UNCERTAIN):
            group = groups.get(confidence)
            if not group:
                continue
            message_queue.put(FoundFiles(
                id=next_id, path=directory, files=tuple(group['files']), bytes=group['bytes'],
                category=', '.join(group['categories']), confidence=confidence))
            next_id += 1

        # Reversed, so the stack pops them back in listed order
        pending.extend(reversed(subfolders))

    # Phase 2: size each matched folder
    for index, item in enumerate(found, start=1):
        if cancel.is_set():
            return True
        message_queue.put(Progress(f'Calculating sizes ({index} of {len(found)})'))
        size = folder_size(item.path, cancel)
        if size is None:
            return True
        message_queue.put(Size(id=item.id, bytes=size.bytes, files=size.files))

    return False


def start_scan(root: str | Path, **options) -> Job:
    return jobs.start(functools.partial(scan, root, **options))
