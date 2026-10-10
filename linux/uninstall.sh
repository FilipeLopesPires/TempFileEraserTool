#!/usr/bin/env bash
# Removes the context menu entries and the tool files installed by install.sh.
set -euo pipefail

PACKAGE_NAME="temp-file-eraser"
DEB_NAME="temp-file-eraser-tool"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '%s\n' "$*"; }

if command -v dpkg-query >/dev/null 2>&1 &&
   dpkg-query -W -f='${Status}' "$DEB_NAME" 2>/dev/null | grep -q 'install ok installed'; then
    printf 'Error: %s\n' "The package edition is installed. Remove it with:
       sudo apt remove $DEB_NAME" >&2
    exit 1
fi

rm -rf "$DATA_HOME/$PACKAGE_NAME"
rm -f "$HOME/.local/bin/$PACKAGE_NAME"
rm -f "$DATA_HOME/nautilus-python/extensions/temp-file-eraser-nautilus.py"
# Python leaves a compiled copy beside it, which Nautilus would still load
rm -f "$DATA_HOME"/nautilus-python/extensions/__pycache__/temp-file-eraser-nautilus.*.pyc
rm -f "$DATA_HOME/nautilus/scripts/Clean up temp and cache folders"
rm -f "$DATA_HOME/nemo/actions/temp-file-eraser.nemo_action"
rm -f "$DATA_HOME/kio/servicemenus/temp-file-eraser.desktop"
rm -f "$DATA_HOME/kservices5/ServiceMenus/temp-file-eraser.desktop"
rm -f "$DATA_HOME/applications/temp-file-eraser.desktop"

if [[ -f "$CONFIG_HOME/Thunar/uca.xml" && -f "$SOURCE_DIR/integrations/thunar_action.py" ]]; then
    python3 "$SOURCE_DIR/integrations/thunar_action.py" --remove "$CONFIG_HOME/Thunar/uca.xml" \
        2>/dev/null || true
fi

command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$DATA_HOME/applications" 2>/dev/null || true

if pgrep -x nautilus >/dev/null 2>&1; then
    nautilus -q >/dev/null 2>&1 || true
fi

say 'Context menu entries and tool files removed.'
