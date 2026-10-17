#!/usr/bin/env bash
# Builds moonfetch.dll and installs it with the Lua wrapper into moonloader/lib.
#   ./install.sh                       repo cloned inside moonloader/
#   ML_DIR="C:/Games/GTA/moonloader" ./install.sh
set -e
cd "$(dirname "$0")"
ML="${ML_DIR:-$(cd .. && pwd)}"
[ -d "$ML/lib" ] || { echo "moonloader/lib not found in '$ML' - set ML_DIR"; exit 1; }

cargo build --release
cp target/i686-pc-windows-msvc/release/moonfetch.dll "$ML/lib/"
cp lua/moonfetch.lua "$ML/lib/"
echo "installed into $ML/lib"
