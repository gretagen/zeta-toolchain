#!/bin/sh
# build.sh — assemble the Zeta package manager into the install layout.
#
# Invoked by zeta-makepkg from inside the extracted source tree with $DESTDIR
# pointing at the staging root. This is a Lua-application package (no native
# build step), so we just lay the source tree out under the FHS paths that the
# shipped launcher expects:
#
#   /usr/bin/zeta            launcher
#   /usr/lib/zeta/zeta.lua   entry point
#   /usr/lib/zeta/lib/*.lua  modules

set -eu

echo "==> Assembling zeta (custom)"

install -d "$DESTDIR/usr/bin"
install -d "$DESTDIR/usr/lib/zeta/lib"

# Launcher: hardcode the installed entry-point path. The repo's bin/zeta uses
# a relative path valid only in the source tree.
install -m755 bin/zeta "$DESTDIR/usr/bin/.zeta-launcher"
sed -e 's#$(dirname "$0")/../zeta.lua#/usr/lib/zeta/zeta.lua#' \
  bin/zeta > "$DESTDIR/usr/bin/zeta"
chmod 755 "$DESTDIR/usr/bin/zeta"
rm -f "$DESTDIR/usr/bin/.zeta-launcher"

# Entry point and all modules
install -m644 zeta.lua "$DESTDIR/usr/lib/zeta/zeta.lua"
install -m644 lib/*.lua "$DESTDIR/usr/lib/zeta/lib/"

echo "==> Install complete"