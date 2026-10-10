#!/usr/bin/env bash
# Builds the Linux release assets:
#
#   temp-file-eraser-tool_<version>_all.deb   package edition
#   TempFileEraserTool-Linux-Script.tar.gz    script edition
#
# The tarball name carries no version so the README's releases/latest/download
# links keep working, matching the Windows assets.
#
#   ./build.sh [--output DIR] [--version X.Y.Z] [--skip-deb]
set -euo pipefail

LINUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LINUX_DIR/.." && pwd)"
PACKAGE_NAME="temp-file-eraser-tool"

OUTPUT_DIR="$REPO_DIR/dist"
VERSION=""
SKIP_DEB=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --skip-deb) SKIP_DEB=1; shift ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -n "$VERSION" ]] || VERSION="$(head -n 1 "$REPO_DIR/VERSION" | tr -d '[:space:]')"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "Error: version '%s' must be x.y.z, e.g. 1.2.0 (no 'v' prefix).\n" "$VERSION" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$PACKAGE_NAME"_*.deb "$OUTPUT_DIR/TempFileEraserTool-Linux-Script.tar.gz"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# ------------------------------------------------------- script edition tarball
# A flat layout, so install.sh finds everything next to itself
script_root="$staging/TempFileEraserTool-Linux"
mkdir -p "$script_root/tempfileeraser" "$script_root/integrations"
cp "$LINUX_DIR"/tempfileeraser/*.py "$script_root/tempfileeraser/"
cp -r "$LINUX_DIR"/integrations/. "$script_root/integrations/"
cp "$LINUX_DIR/install.sh" "$LINUX_DIR/uninstall.sh" "$script_root/"
cp "$REPO_DIR/rules/rules.json" "$script_root/rules.json"
cp "$REPO_DIR/VERSION" "$script_root/VERSION"
cp "$REPO_DIR/LICENSE.md" "$script_root/"
chmod +x "$script_root/install.sh" "$script_root/uninstall.sh"
tar -czf "$OUTPUT_DIR/TempFileEraserTool-Linux-Script.tar.gz" -C "$staging" TempFileEraserTool-Linux
printf 'Built %s\n' "$OUTPUT_DIR/TempFileEraserTool-Linux-Script.tar.gz"

if ((SKIP_DEB)); then
    exit 0
fi
command -v dpkg-deb >/dev/null 2>&1 || { printf 'Error: dpkg-deb was not found.\n' >&2; exit 1; }

# ----------------------------------------------------------------- deb package
root="$staging/deb"
install -d "$root/DEBIAN" \
           "$root/usr/bin" \
           "$root/usr/lib/temp-file-eraser/tempfileeraser" \
           "$root/usr/share/nautilus-python/extensions" \
           "$root/usr/share/applications" \
           "$root/usr/share/doc/$PACKAGE_NAME"

install -m 644 "$LINUX_DIR"/tempfileeraser/*.py "$root/usr/lib/temp-file-eraser/tempfileeraser/"
install -m 644 "$REPO_DIR/rules/rules.json" "$root/usr/lib/temp-file-eraser/tempfileeraser/rules.json"
printf '%s\n' "$VERSION" > "$root/usr/lib/temp-file-eraser/tempfileeraser/VERSION"
chmod 644 "$root/usr/lib/temp-file-eraser/tempfileeraser/VERSION"

install -m 755 "$LINUX_DIR/packaging/temp-file-eraser" "$root/usr/bin/temp-file-eraser"
install -m 644 "$LINUX_DIR/integrations/nautilus/temp-file-eraser-nautilus.py" \
               "$root/usr/share/nautilus-python/extensions/"
# The Scripts fallback is deliberately not packaged: Nautilus only reads the
# per-user ~/.local/share/nautilus/scripts, which a system package must not write
# to. The package relies on python3-nautilus instead, and postinst says so if it
# is missing.
install -m 644 "$LINUX_DIR/integrations/temp-file-eraser.desktop" "$root/usr/share/applications/"
install -m 644 "$REPO_DIR/LICENSE.md" "$root/usr/share/doc/$PACKAGE_NAME/copyright"

sed "s/@VERSION@/$VERSION/" "$LINUX_DIR/packaging/debian/control" > "$root/DEBIAN/control"
chmod 644 "$root/DEBIAN/control"
for script in postinst prerm; do
    if [[ -f "$LINUX_DIR/packaging/debian/$script" ]]; then
        install -m 755 "$LINUX_DIR/packaging/debian/$script" "$root/DEBIAN/$script"
    fi
done

deb="$OUTPUT_DIR/${PACKAGE_NAME}_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$root" "$deb" >/dev/null
printf 'Built %s\n' "$deb"
