"""Moves folders and files to the Trash, or erases them permanently.

Ported from src/TempFolderRemover.ps1. The Recycle Bin becomes the XDG trash, via
Gio so the freedesktop.org spec is honoured: the right .Trash-$uid for the
filesystem the item lives on, and a restore entry the file manager understands.

Permanent deletion keeps the Windows edition's hand-rolled walk rather than using
shutil.rmtree, for two reasons: it produces the per-item error list the summary
dialog shows, and it unlinks symlinks instead of following them.
"""

from __future__ import annotations

import errno
import functools
import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from gi.repository import Gio, GLib

from . import jobs
from .jobs import Job, Progress, Removed

TRASH = 'Trash'
PERMANENT = 'Permanent'

NO_TRASH_HINT = ('This filesystem has no Trash folder. Try Erase permanently instead.')


@dataclass(frozen=True)
class RemovalResult:
    path: str
    success: bool
    error: str | None = None


def format_errors(errors: Sequence[str]) -> str:
    text = errors[0]
    if len(errors) > 1:
        text += f' (and {len(errors) - 1} more)'
    return text


def _message(error: OSError) -> str:
    return error.strerror or str(error)


def _trash(path: str) -> None:
    """Raises GLib.Error, with a usable message for the common failures."""
    Gio.File.new_for_path(str(path)).trash(None)


def _trash_error_text(error: GLib.Error) -> str:
    if error.matches(Gio.io_error_quark(), int(Gio.IOErrorEnum.NOT_SUPPORTED)):
        return NO_TRASH_HINT
    return error.message


def _make_writable(path: Path) -> None:
    """On Linux it is the parent directory's write bit that governs unlinking."""
    try:
        mode = path.stat().st_mode
        os.chmod(path, mode | stat.S_IWUSR | stat.S_IXUSR)
    except OSError:
        pass


def remove_tree(path: str | Path, errors: list[str]) -> None:
    """Deletes path and everything below it, deepest first.

    Symlinks are unlinked as links, so their targets survive.
    """
    root = Path(path)
    folders = [root]
    pending = [root]

    while pending:
        current = pending.pop()
        try:
            with os.scandir(current) as scanned:
                entries = list(scanned)
        except OSError as error:
            errors.append(f'{current}: {_message(error)}')
            continue
        for entry in entries:
            try:
                if entry.is_dir(follow_symlinks=False):
                    folders.append(Path(entry.path))
                    pending.append(Path(entry.path))
                else:
                    os.unlink(entry.path)
            except OSError as error:
                if error.errno in (errno.EACCES, errno.EPERM):
                    _make_writable(current)
                    try:
                        os.unlink(entry.path)
                        continue
                    except OSError as retry:
                        error = retry
                errors.append(f'{entry.path}: {_message(error)}')

    for folder in reversed(folders):
        try:
            os.rmdir(folder)
        except OSError as error:
            # A folder left non-empty by an earlier failure is already explained
            if not errors:
                errors.append(f'{folder}: {_message(error)}')


def remove_folder(path: str | Path, mode: str) -> RemovalResult:
    path = str(path)
    try:
        if not os.path.isdir(path):
            return RemovalResult(path, True)
        if mode == TRASH:
            _trash(path)
        else:
            errors: list[str] = []
            remove_tree(path, errors)
            if errors:
                return RemovalResult(path, False, format_errors(errors))
        return RemovalResult(path, True)
    except GLib.Error as error:
        return RemovalResult(path, False, _trash_error_text(error))
    except OSError as error:
        return RemovalResult(path, False, _message(error))


def remove_files(folder: str | Path, names: Sequence[str], mode: str) -> RemovalResult:
    """Deletes the named files in folder, never the folder itself."""
    folder = str(folder)
    errors: list[str] = []
    for name in names:
        path = os.path.join(folder, name)
        try:
            if not os.path.lexists(path):
                continue
            if mode == TRASH:
                _trash(path)
            else:
                os.unlink(path)
        except GLib.Error as error:
            errors.append(f'{name}: {_trash_error_text(error)}')
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EPERM):
                _make_writable(Path(folder))
                try:
                    os.unlink(path)
                    continue
                except OSError as retry:
                    error = retry
            errors.append(f'{name}: {_message(error)}')

    if errors:
        return RemovalResult(folder, False, format_errors(errors))
    return RemovalResult(folder, True)


def run_removal(items: Sequence[dict], mode: str, message_queue, cancel) -> bool:
    """Removes each item and reports a Removed message per item. True if stopped early.

    Items are dicts: id, kind ('Folder' or 'Files'), path, files, bytes.
    """
    for index, item in enumerate(items, start=1):
        if cancel.is_set():
            return True
        message_queue.put(Progress(f'Removing {index} of {len(items)}: {item["path"]}',
                                   step=index, steps=len(items)))
        if item.get('kind') == 'Files':
            result = remove_files(item['path'], item.get('files') or (), mode)
        else:
            result = remove_folder(item['path'], mode)
        message_queue.put(Removed(id=item['id'], path=item['path'], success=result.success,
                                  error=result.error, bytes=item.get('bytes')))
    return False


def start_removal(items: Sequence[dict], mode: str) -> Job:
    return jobs.start(functools.partial(run_removal, items, mode))
