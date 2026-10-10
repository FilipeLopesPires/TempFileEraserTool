#!/usr/bin/env python3
"""Adds or removes the Thunar custom action in ~/.config/Thunar/uca.xml.

Thunar keeps every custom action in one file, so this cannot simply drop a file
in place like the other file managers: the existing actions have to survive. The
action is identified by its unique-id, so installing twice replaces rather than
duplicates.

    thunar_action.py --install <uca.xml> <command>
    thunar_action.py --remove  <uca.xml>
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

UNIQUE_ID = 'temp-file-eraser-tool-1'
LABEL = 'Clean up temp and cache folders'
DESCRIPTION = 'Find regenerable temp, cache and build folders below this folder'


def load(path: Path) -> ElementTree.Element:
    if not path.exists():
        return ElementTree.Element('actions')
    try:
        root = ElementTree.parse(path).getroot()
    except ElementTree.ParseError as error:
        raise SystemExit(f'{path} is not valid XML: {error}')
    return root if root.tag == 'actions' else ElementTree.Element('actions')


def drop_existing(root: ElementTree.Element) -> None:
    for action in list(root.findall('action')):
        if action.findtext('unique-id') == UNIQUE_ID:
            root.remove(action)


def build(command: str) -> ElementTree.Element:
    action = ElementTree.Element('action')
    for tag, text in (('icon', 'user-trash'), ('name', LABEL), ('unique-id', UNIQUE_ID),
                      ('command', f'{command} %f'), ('description', DESCRIPTION),
                      ('range', ''), ('patterns', '*')):
        ElementTree.SubElement(action, tag).text = text
    ElementTree.SubElement(action, 'directories')   # folders only
    return action


def save(root: ElementTree.Element, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.with_suffix('.xml.bak').write_bytes(path.read_bytes())
    ElementTree.indent(root, space='    ')
    ElementTree.ElementTree(root).write(path, encoding='UTF-8', xml_declaration=True)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    mode, path = argv[0], Path(argv[1])

    root = load(path)
    drop_existing(root)
    if mode == '--install':
        if len(argv) < 3:
            print('--install needs the command to run', file=sys.stderr)
            return 2
        root.append(build(argv[2]))
    elif mode != '--remove':
        print(f'Unknown mode {mode}', file=sys.stderr)
        return 2

    save(root, path)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
