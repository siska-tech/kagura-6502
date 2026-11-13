#!/usr/bin/env bash
# Build cc65 V2.19 (ca65/ld65 for the KAGURA-6502 BIOS and BASIC) from the official
# release tag into build/tools/cc65-2.19 (gitignored). No sudo, nothing installed
# system-wide. Run inside WSL (needs git, make, gcc).
#   tag V2.19 = commit 555282497c3ecf8b313d87d5973093af19c35bd5 (its tools print "V2.18 - Git 5552824")
set -euo pipefail
cd "$(dirname "$0")/../.."
DEST=$(pwd)/build/tools/cc65-2.19
REV=555282497c3ecf8b313d87d5973093af19c35bd5
W=$(mktemp -d)
git clone -q --branch V2.19 --depth 1 https://github.com/cc65/cc65.git "$W/cc65"
[ "$(git -C "$W/cc65" rev-parse HEAD)" = "$REV" ] || { echo "unexpected cc65 revision"; exit 1; }
make -C "$W/cc65" -j"$(nproc)" bin > "$W/build.log" 2>&1 || { tail -30 "$W/build.log"; exit 1; }
mkdir -p "$DEST"; cp -r "$W/cc65/bin" "$W/cc65/cfg" "$W/cc65/asminc" "$DEST/"
"$DEST/bin/ca65" --version
rm -rf "$W"
