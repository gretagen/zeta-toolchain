#!/bin/sh
# build.sh — example custom build script for zeta-makepkg.
#
# Invoked from the extracted source directory.  The tool sets:
#   $DESTDIR  → staging tree root (e.g. /tmp/zeta-makepkg/mytool-.../stage)
#
# This script must compile/assemble the software and install every output
# file under $DESTDIR with standard FHS paths (usr/bin/, usr/lib/, etc.).
#
# For a real project you would replace the example below with:
#   - Go:      go build -o "$DESTDIR/usr/bin/mytool" .
#   - Rust:    cargo build --release && install -D target/release/mytool "$DESTDIR/usr/bin/mytool"
#   - Zig:     zig build -Doptimize=ReleaseSafe --prefix /usr -Ddestdir="$DESTDIR"
#   - Shell:   install -D mytool.sh "$DESTDIR/usr/bin/mytool"
#   - Python:  install -D mytool.py "$DESTDIR/usr/bin/mytool"
#   - Anything you can script.

set -eu

echo "==> Building mytool (custom)"

# Standalone Go binary: init module, build, install
go mod init mytool
go build -o mytool .

# Install into the staging tree
install -Dm755 mytool "$DESTDIR/usr/bin/mytool"

echo "==> Install complete"
