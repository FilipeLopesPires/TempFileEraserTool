"""Find and erase regenerable temp, cache and build folders.

The Linux edition of TempFileEraserTool. Launched from the file manager's context
menu (see linux/install.sh) or from a terminal as `temp-file-eraser [PATH]`.
"""

from pathlib import Path

APP_NAME = 'Temp File Eraser'
APP_ID = 'io.github.filipelopespires.TempFileEraser'


def _read_version() -> str:
    # Installed: a VERSION file beside the package. Repository clone: the one at the root
    here = Path(__file__).resolve().parent
    for candidate in (here / 'VERSION', here.parent.parent / 'VERSION'):
        try:
            return candidate.read_text(encoding='utf-8').strip().splitlines()[0]
        except (OSError, IndexError):
            continue
    return '0.0.0'


__version__ = _read_version()
