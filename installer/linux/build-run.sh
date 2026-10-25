#!/bin/sh
# Builds Karing+-<version>-linux-x64.run: header.sh with the version filled in + the app tar.gz.
#   sh build-run.sh <bundle.tar.gz> <version> <out.run>
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
sed "s/@VERSION@/$2/" "$HERE/header.sh" > "$3"
cat "$1" >> "$3"
chmod 755 "$3"
