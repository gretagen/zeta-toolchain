.PHONY: all install clean

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
LIBDIR  ?= $(PREFIX)/lib/zeta-toolchain

all:
	@echo "zeta-toolchain: nothing to compile (Lua scripts)"
	@echo "  make install  →  $(BINDIR)  +  $(LIBDIR)"

install:
	install -Dm755 cli/zeta-cli         $(DESTDIR)$(BINDIR)/zeta-cli
	install -Dm755 builder/zeta-makepkg $(DESTDIR)$(BINDIR)/zeta-makepkg
	install -d $(DESTDIR)$(LIBDIR)
	cp -r lib/* $(DESTDIR)$(LIBDIR)

clean:
	rm -rf /tmp/zeta-makepkg

.DEFAULT_GOAL := all
