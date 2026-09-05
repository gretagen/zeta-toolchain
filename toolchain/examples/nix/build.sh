#!/bin/sh
# build.sh — assemble the official Nix prebuilt binary payload into a
# self-contained /nix layout plus an FHS /usr/bin shim.
#
# The official tarball (releases.nixos.org/nix/nix-2.35.2/) is the multi-user
# installer payload: a dir with store/, .reginfo and the install scripts. We
# replicate the installer's single-user store layout that is host-independent:
#
#   /nix/store/<hash>-nix-2.35.2/...    (the full 2.35.2 closure, read-only)
#   /nix/var/nix/db/                   (closure pre-registered via .reginfo)
#   /usr/bin/<nix tools>               (symlinks into the store bin dir)
#   /etc/profile.d/nix.sh              (symlink into the store nix.sh)
#
# Requires a working `nix-store` on the build host. It is only used to
# register the .reginfo against the staged store (local?root= override); the
# shipped payload is fully self-contained. The nix binary itself is NOT
# executed on the host, so this needs no 2.35.2 closure in the host store.

set -eu

NIX_OUT="irfrbndi76zhkvqsfhmsn4a99iafck29-nix-2.35.2"
NIX_TREE="$DESTDIR/nix"

# --- locate a host nix-store for db registration ---------------------------
NIX_STORE_BIN=""
if command -v nix-store >/dev/null 2>&1; then
    NIX_STORE_BIN="$(command -v nix-store)"
elif [ -x "$HOME/.nix-profile/bin/nix-store" ]; then
    NIX_STORE_BIN="$HOME/.nix-profile/bin/nix-store"
else
    echo "nix: a working nix-store on the build host is required for .reginfo import" >&2
    exit 1
fi

# --- store closure, read-only (mirrors the official install script) --------
mkdir -p "$NIX_TREE/store" "$NIX_TREE/var/nix"
for i in store/*; do
    n="$(basename "$i")"
    if [ ! -e "$NIX_TREE/store/$n" ]; then
        cp -RPp "$i" "$NIX_TREE/store/$n"
        chmod -R a-w "$NIX_TREE/store/$n"
    fi
done

# --- register the closure in the staged db (pre-marks paths valid, so the
# --- shipped store is invisible to nix-store --gc and matches the narHash
# --- recorded for each path). ----------------------------------------------
"$NIX_STORE_BIN" --store "local?root=$DESTDIR" --load-db < .reginfo

# --- flatten the WAL so the shipped db is a clean single file --------------
DB="$NIX_TREE/var/nix/db/db.sqlite"
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;"
    rm -f "$NIX_TREE/var/nix/db/db.sqlite-shm" "$NIX_TREE/var/nix/db/db.sqlite-wal"
fi

# --- FHS shim: symlink every tool from the store bin dir into /usr/bin -----
NIX_STORE_BIN_DIR="$NIX_TREE/store/$NIX_OUT/bin"
mkdir -p "$DESTDIR/usr/bin"
for t in "$NIX_STORE_BIN_DIR"/*; do
    ln -s "/nix/store/$NIX_OUT/bin/$(basename "$t")" "$DESTDIR/usr/bin/$(basename "$t")"
done

# --- login-shell env hook (sets NIX_PROFILES, PATH, XDG_DATA_DIRS) ---------
mkdir -p "$DESTDIR/etc/profile.d"
ln -s "/nix/store/$NIX_OUT/etc/profile.d/nix.sh" "$DESTDIR/etc/profile.d/nix.sh"

echo "==> nix staged: $(ls "$NIX_TREE/store" | wc -l) store paths, closure registered in db"