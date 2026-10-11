#!/bin/sh
# anipaper — upstream Makefile defaults PREFIX=/usr/local; force /usr and
# the conventional /usr/share/man location for the man page.
set -e
test -n "$DESTDIR"
make PREFIX=/usr
make install PREFIX=/usr MANDIR=/usr/share/man DESTDIR="$DESTDIR"