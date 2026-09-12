#!/bin/sh
# build.sh — stage the official static Telegram Desktop build under $DESTDIR.
# The source tarball extracts to Telegram/{Telegram,Updater}; we relayout
# FHS-clean: /usr/share/telegram/ + a /usr/bin/telegram-desktop launcher.
set -eu
mkdir -p "$DESTDIR/usr/share/telegram" "$DESTDIR/usr/bin"
cp -a Telegram Updater "$DESTDIR/usr/share/telegram/"
printf '#!/bin/sh\nexec /usr/share/telegram/Telegram "$@"\n' > "$DESTDIR/usr/bin/telegram-desktop"
chmod 0755 "$DESTDIR/usr/bin/telegram-desktop" "$DESTDIR/usr/share/telegram/Telegram" "$DESTDIR/usr/share/telegram/Updater"