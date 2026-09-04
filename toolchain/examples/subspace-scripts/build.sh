#!/bin/sh
# build.sh — assemble the subspace-scripts into the install layout.
#
# Invoked by zeta-makepkg from inside the extracted source tree with $DESTDIR
# pointing at the staging root. These are bash scripts; no build step, just
# FHS placement matching the established package layout:
#
#   /usr/bin/subspace-cli, subspace-merge, subspace-unmerge
#   /subspace/subspace-enter, subspace-run, subspace-sync

set -eu

echo "==> Assembling subspace-scripts (custom)"

install -d "$DESTDIR/usr/bin"
install -d "$DESTDIR/subspace"

install -m755 subspace-cli       "$DESTDIR/usr/bin/subspace-cli"
install -m755 subspace-merge     "$DESTDIR/usr/bin/subspace-merge"
install -m755 subspace-unmerge   "$DESTDIR/usr/bin/subspace-unmerge"
install -m755 subspace-enter     "$DESTDIR/subspace/subspace-enter"
install -m755 subspace-run       "$DESTDIR/subspace/subspace-run"
install -m755 subspace-sync      "$DESTDIR/subspace/subspace-sync"

echo "==> Install complete"