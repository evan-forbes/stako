PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
ZIG     ?= zig

BIN := zig-out/bin/stako

.PHONY: all build install uninstall test clean

all: build

build:
	$(ZIG) build -Doptimize=ReleaseSafe

$(BIN): build

install: $(BIN)
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(BIN) $(DESTDIR)$(BINDIR)/stako
	@echo "installed $(DESTDIR)$(BINDIR)/stako"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/stako

test:
	$(ZIG) build test

clean:
	rm -rf zig-out .zig-cache
