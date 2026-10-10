#!/bin/sh
set -e

# Workaround: explicitly use /usr/lib to avoid broken /usr/local/lib linker scripts
export LIBRARY_PATH="/usr/lib"
export LDFLAGS="-L/usr/lib"

echo 'linux' | ./Configure -des \
  -Dprefix=/usr \
  -Dvendorprefix=/usr \
  -Dman1dir=none \
  -Dman3dir=none \
  -Duseshrplib \
  -Dusethreads \
  -Dcc='cc' \
  -Doptimize='-O2' \
  -Dlibpth='/usr/lib /lib' \
  -Dloclibpth='/usr/lib'

make -j"$(nproc)"
make install DESTDIR="$DESTDIR"
