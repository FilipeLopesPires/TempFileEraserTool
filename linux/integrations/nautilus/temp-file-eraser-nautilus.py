"""Adds "Clean up temp and cache folders" to the Nautilus context menu.

Installed to ~/.local/share/nautilus-python/extensions (Script edition) or
/usr/share/nautilus-python/extensions (package). Needs the python3-nautilus
package. Nautilus must be restarted to pick it up: nautilus -q

Two Nautilus generations are supported from this one file:

  - nautilus-python 1.2.x (Ubuntu 22.04, Nautilus 42) uses the Nautilus 3.0
    typelib and calls get_file_items(window, files).
  - nautilus-python 4.x (Ubuntu 23.10 and newer) uses Nautilus 4.0 and calls
    get_file_items(files).

Taking *args and reading the last argument covers both.

This runs inside the Nautilus process, so it does as little as possible: it never
imports the tool, and launches it detached so a scan can never block the file
manager.
"""

import os
import subprocess

import gi

for _api in ('4.0', '3.0'):
    try:
        gi.require_version('Nautilus', _api)
        break
    except ValueError:
        continue

from gi.repository import GObject, Nautilus  # noqa: E402

MENU_LABEL = 'Clean up temp and cache folders'
MENU_TIP = 'Find regenerable temp, cache and build folders below this folder'
COMMAND = 'temp-file-eraser'


def _launch(path):
    # start_new_session detaches the tool, so closing Nautilus never kills a scan
    try:
        subprocess.Popen([COMMAND, path], start_new_session=True)
    except OSError:
        local = os.path.expanduser('~/.local/bin/temp-file-eraser')
        if os.path.exists(local):
            subprocess.Popen([local, path], start_new_session=True)


def _path_of(file_info):
    if file_info is None or file_info.get_uri_scheme() != 'file':
        return None
    if not file_info.is_directory():
        return None
    return file_info.get_location().get_path()


def _menu_item(path, name):
    item = Nautilus.MenuItem(name=name, label=MENU_LABEL, tip=MENU_TIP)
    item.connect('activate', lambda _item: _launch(path))
    return item


class TempFileEraserExtension(GObject.GObject, Nautilus.MenuProvider):
    """One entry when a folder is selected, one for the folder being browsed."""

    def get_file_items(self, *args):
        files = args[-1]
        if len(files) != 1:
            return []
        path = _path_of(files[0])
        if path is None:
            return []
        return [_menu_item(path, 'TempFileEraser::clean_selected')]

    def get_background_items(self, *args):
        path = _path_of(args[-1])
        if path is None:
            return []
        return [_menu_item(path, 'TempFileEraser::clean_current')]
