"""Entry point.

    temp-file-eraser PATH            review window
    temp-file-eraser PATH --list     print what would be erased, change nothing

The file manager always passes a path (see linux/integrations). --list exists so
the scanner and the rules can be exercised without a display, and so the tool can
be used from a script.
"""

from __future__ import annotations

import argparse
import queue
import sys
import threading
from pathlib import Path

from . import APP_NAME, __version__
from .formatting import (ELLIPSIS, format_byte_size, format_count, format_row_type,
                         format_selection_summary, selection_summary)
from .jobs import Failure, FoundFiles, FoundFolder, Size
from .model import Row
from .scanner import (find_protected_zone, is_large_scan_root, protected_zones,
                      resolve_scan_root, scan)

PROTECTED_MESSAGE = (
    '{path} is inside a protected location ({zone}).\n\n'
    'Folders there belong to the system or to installed apps, and removing them could '
    'break things. Choose a folder that holds your own projects instead.')


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog='temp-file-eraser',
        description='Find and erase regenerable temp, cache and build folders.')
    parser.add_argument('path', nargs='?', help='folder to scan')
    parser.add_argument('--list', '--dry-run', dest='list_only', action='store_true',
                        help='print what would be erased and exit, changing nothing')
    parser.add_argument('--version', action='version', version=f'{APP_NAME} {__version__}')
    return parser.parse_args(argv)


def collect(root: Path, **options) -> tuple[list[Row], list[str], bool]:
    """Runs a scan to completion on this thread. Returns (rows, errors, cancelled)."""
    message_queue: queue.SimpleQueue = queue.SimpleQueue()
    cancelled = scan(root, message_queue, threading.Event(), **options)

    rows: dict[int, Row] = {}
    errors: list[str] = []
    while True:
        try:
            message = message_queue.get_nowait()
        except queue.Empty:
            break
        if isinstance(message, (FoundFolder, FoundFiles)):
            rows[message.id] = Row.from_message(message)
        elif isinstance(message, Size) and message.id in rows:
            rows[message.id].bytes = message.bytes
        elif isinstance(message, Failure):
            errors.append(message.message)
    return list(rows.values()), errors, cancelled


def list_findings(root: Path, stream=None) -> int:
    # Resolved here, not in the signature: sys.stdout can be replaced after import
    stream = stream or sys.stdout
    rows, errors, _ = collect(root)
    if not rows:
        print(f'No temp, cache or build folders or files were found in {root}', file=stream)
        for message in errors:
            print(f'Error: {message}', file=stream)
        return 0

    rows.sort(key=lambda row: (row.bytes is None, -(row.bytes or 0), row.path))
    width = max(len(row.path) for row in rows)
    for row in rows:
        size = format_byte_size(row.bytes) if row.bytes is not None else 'unknown'
        mark = ' ' if row.checked else '-'
        print(f'{mark} {row.path:<{width}}  {size:>12}  {format_row_type(row)}', file=stream)

    summary = selection_summary(rows)
    print(f'\n{format_count(len(rows), "item")} found. '
          f'{format_selection_summary(summary)}', file=stream)
    print('Rows marked "-" start unchecked in the review window.', file=stream)
    return 0


def main(argv: list[str] | None = None) -> int:
    options = parse_args(argv)

    if not options.path:
        if not options.list_only:
            print('No folder was given. Usage: temp-file-eraser PATH', file=sys.stderr)
            return 2
        options.path = '.'

    try:
        root = resolve_scan_root(options.path)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    zone = find_protected_zone(root, protected_zones())
    if zone:
        message = PROTECTED_MESSAGE.format(path=root, zone=zone)
        if options.list_only:
            print(message, file=sys.stderr)
            return 1
        from .dialogs import show_message
        show_message(message, 'error')
        return 1

    if options.list_only:
        if is_large_scan_root(root):
            print(f'Scanning {root} may take a long time{ELLIPSIS}', file=sys.stderr)
        return list_findings(root)

    from .window import run
    return run(root)


if __name__ == '__main__':
    sys.exit(main())
