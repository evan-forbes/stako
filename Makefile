PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
ZIG     ?= zig
CODEX_HOME ?= $(HOME)/.codex
CLAUDE_HOME ?= $(HOME)/.claude
CODEX_SKILLS_DIR ?= $(CODEX_HOME)/skills
CLAUDE_SKILLS_DIR ?= $(CLAUDE_HOME)/skills

BIN := zig-out/bin/stako
STAKO_SKILL_SRC := $(CURDIR)/skills/stako
CODEX_STAKO_SKILL := $(CODEX_SKILLS_DIR)/stako
CLAUDE_STAKO_SKILL := $(CLAUDE_SKILLS_DIR)/stako

.PHONY: all build install uninstall skill test clean

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

skill:
	@test -f "$(STAKO_SKILL_SRC)/SKILL.md"
	mkdir -p "$(CODEX_SKILLS_DIR)" "$(CLAUDE_SKILLS_DIR)"
	@if [ -e "$(CODEX_STAKO_SKILL)" ] && [ ! -L "$(CODEX_STAKO_SKILL)" ]; then \
		echo "refusing to replace non-symlink $(CODEX_STAKO_SKILL)" >&2; \
		exit 1; \
	fi
	@if [ -e "$(CLAUDE_STAKO_SKILL)" ] && [ ! -L "$(CLAUDE_STAKO_SKILL)" ]; then \
		echo "refusing to replace non-symlink $(CLAUDE_STAKO_SKILL)" >&2; \
		exit 1; \
	fi
	ln -sfn "$(STAKO_SKILL_SRC)" "$(CODEX_STAKO_SKILL)"
	ln -sfn "$(STAKO_SKILL_SRC)" "$(CLAUDE_STAKO_SKILL)"
	@echo "installed stako skill:"
	@echo "  $(CODEX_STAKO_SKILL) -> $(STAKO_SKILL_SRC)"
	@echo "  $(CLAUDE_STAKO_SKILL) -> $(STAKO_SKILL_SRC)"

test:
	$(ZIG) build test

clean:
	rm -rf zig-out .zig-cache
