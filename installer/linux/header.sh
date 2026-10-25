#!/bin/sh
# Karing+ installer for Linux: one file that holds the whole app (a tar.gz appended after this script).
#
#   sh Karing+-<version>-linux-x64.run              install or update (asks for sudo)
#   sh Karing+-<version>-linux-x64.run --uninstall  remove
#
# Installs to /opt/karing-plus, adds the "karing-plus" command and a menu entry. User data
# (~/.local/share/KaringPlus) is kept on update and uninstall.
set -e

APP="Karing+"
VERSION="@VERSION@"
DIR=/opt/karing-plus
BIN=/usr/local/bin/karing-plus
DESKTOP=/usr/share/applications/karing-plus.desktop
ICON=/usr/share/icons/hicolor/128x128/apps/karing-plus.png
SERVICE=karingplus.service

if [ "$(id -u)" -ne 0 ]; then
	if command -v sudo >/dev/null 2>&1; then
		exec sudo sh "$0" "$@"
	fi
	echo "$APP: run as root (sudo sh $0)" >&2
	exit 1
fi

stop_old() {
	# The app and the core service from an earlier install must not keep files open.
	pkill -f "$DIR/karing" 2>/dev/null || true
	if command -v systemctl >/dev/null 2>&1; then
		systemctl stop "$SERVICE" 2>/dev/null || true
	fi
}

if [ "$1" = "--uninstall" ]; then
	stop_old
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable "$SERVICE" 2>/dev/null || true
		rm -f "/etc/systemd/system/$SERVICE"
		systemctl daemon-reload 2>/dev/null || true
	fi
	rm -rf "$DIR" "$BIN" "$DESKTOP" "$ICON"
	echo "$APP removed. Settings in ~/.local/share/KaringPlus are kept."
	exit 0
fi

echo "Installing $APP $VERSION to $DIR ..."
stop_old

# The archive starts on the line after __PAYLOAD__.
LINE=$(awk '/^__PAYLOAD__$/ { print NR + 1; exit }' "$0")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
tail -n +"$LINE" "$0" | tar -xzf - -C "$TMP"

# Fresh copy: files of an earlier version must not stay behind.
rm -rf "$DIR"
mkdir -p "$(dirname "$DIR")"
mv "$TMP/karingplus" "$DIR"
chmod 755 "$DIR/karing"

cat > "$BIN" <<EOF
#!/bin/sh
exec "$DIR/karing" "\$@"
EOF
chmod 755 "$BIN"

ICON_SRC=$(ls "$DIR"/data/flutter_assets/assets/images/app_icon_128.png 2>/dev/null | head -n 1)
if [ -n "$ICON_SRC" ]; then
	mkdir -p "$(dirname "$ICON")"
	cp "$ICON_SRC" "$ICON"
fi

mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$APP
Comment=VPN client
Exec=$DIR/karing
Icon=karing-plus
Terminal=false
Categories=Network;
EOF
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q 2>/dev/null || true

echo "$APP $VERSION installed. Start it from the menu or with: karing-plus"
echo "Remove: sudo sh $0 --uninstall"
exit 0
__PAYLOAD__
