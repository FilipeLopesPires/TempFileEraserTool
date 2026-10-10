"""Text shown in the review window, the summary dialogs and the CLI listing.

Ported from the Format-* functions in src/Clear-TempFolders.ps1, with the Recycle
Bin renamed to the Trash. Display only: nothing here touches the filesystem, which
is what makes it the cheapest part of the tool to test.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence

from .model import FILES_ROW, Row
from .rules import CERTAIN

MAX_LISTED_NAMES = 15
MAX_TYPE_NAMES = 3
SEPARATOR = ' · '
ELLIPSIS = '…'

UNITS = ('bytes', 'KB', 'MB', 'GB', 'TB')


def format_count(count: int, singular: str, plural: str | None = None) -> str:
    if count == 1:
        return f'1 {singular}'
    return f'{count} {plural or singular + "s"}'


def format_byte_size(size: int) -> str:
    value = float(size)
    unit = 0
    while value >= 1024 and unit < len(UNITS) - 1:
        value /= 1024
        unit += 1
    if unit == 0:
        return f'{size} bytes'
    return f'{value:,.1f} {UNITS[unit]}'


def format_name_list(names: Sequence[str]) -> str:
    shown = [f'   - {name}' for name in names[:MAX_LISTED_NAMES]]
    if len(names) > MAX_LISTED_NAMES:
        shown.append(f'   ... and {len(names) - MAX_LISTED_NAMES} more')
    return '\n'.join(shown)


def format_row_type(row: Row) -> str:
    if row.kind == FILES_ROW:
        noun = 'temp file' if row.confidence == CERTAIN else 'possible temp file'
        names = ', '.join(row.files[:MAX_TYPE_NAMES])
        if len(row.files) > MAX_TYPE_NAMES:
            names += f', {ELLIPSIS}'
        return f'{format_count(len(row.files), noun)}: {names}'
    if row.note:
        return f'{row.category} ({row.note})'
    if row.confidence != CERTAIN:
        return f'{row.category} (no project file found)'
    return row.category


@dataclass(frozen=True)
class SelectionSummary:
    total: int = 0
    selected: int = 0
    bytes: int = 0
    unsized: int = 0


def selection_summary(rows: Iterable[Row]) -> SelectionSummary:
    rows = list(rows)
    selected = 0
    total_bytes = 0
    unsized = 0
    for row in rows:
        if not row.checked:
            continue
        selected += 1
        if row.bytes is None:
            unsized += 1
        else:
            total_bytes += row.bytes
    return SelectionSummary(len(rows), selected, total_bytes, unsized)


def format_selection_summary(summary: SelectionSummary, still_scanning: bool = False) -> str:
    text = f'Selected {summary.selected} of {format_count(summary.total, "item")}'
    if summary.selected == 0:
        return text

    size = format_byte_size(summary.bytes)
    if summary.unsized == 0:
        return f'{text}{SEPARATOR}{size}'
    reason = 'still calculating' if still_scanning else 'some sizes unknown'
    return f'{text}{SEPARATOR}at least {size} ({reason})'


@dataclass(frozen=True)
class EraseSummary:
    text: str
    icon: str   # 'information' or 'warning'


def format_erase_summary(results: Sequence, mode: str, errors: Sequence[str] = ()) -> EraseSummary:
    removed = [result for result in results if result.success]
    failed = [result for result in results if not result.success]
    total = sum(result.bytes for result in removed if getattr(result, 'bytes', None))
    size = format_byte_size(total)

    if not removed:
        text = 'Nothing was removed.'
    elif mode == 'Trash':
        text = (f'Moved {format_count(len(removed), "item")} to the Trash ({size}).\n'
                'Empty the Trash to free the space.')
    else:
        text = f'Erased {format_count(len(removed), "item")}, freeing {size}.'

    if failed:
        text += f'\n\nCould not remove {format_count(len(failed), "item")}:\n'
        text += format_name_list([f'{result.path}: {result.error}' for result in failed])
    for message in errors:
        text += f'\n\nError: {message}'

    return EraseSummary(text, 'warning' if failed or errors else 'information')
