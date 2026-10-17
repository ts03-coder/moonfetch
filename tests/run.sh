#!/usr/bin/env bash
# Runs moonfetch_vs_copas.lua outside the game on the game's own lua51.dll.
# moonfetch must be installed first (../install.sh); copas/luasocket/luasec come from moonloader/lib.
#   ./run.sh            all tests
#   ./run.sh noremote   skip internet tests (HTTPS)
#   ML_DIR="C:/Games/GTA/moonloader" ./run.sh
set -e
cd "$(dirname "$0")"
ML="${ML_DIR:-$(cd ../.. && pwd)}"
ML="$(cd "$ML" && pwd -W)"
GAME="$(cd "$ML/.." && pwd -W)"

[ -f luahost.exe ] || rustc --target i686-pc-windows-msvc -O luahost.rs
python server.py 8765 &
SRV=$!
trap 'kill $SRV 2>/dev/null; taskkill //F //PID "$(netstat -ano | awk "/127.0.0.1:8765 .*LISTENING/{print \$NF; exit}")" >/dev/null 2>&1 || true' EXIT
sleep 1

ML_DIR="$ML" MOONFETCH_TEST_ARGS="$1" ./luahost.exe "$GAME/lua51.dll" harness.lua
