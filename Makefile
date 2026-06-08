PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
ZIG     ?= zig
PYTHON  ?= python3
CODEX_HOME ?= $(HOME)/.codex
CLAUDE_HOME ?= $(HOME)/.claude
CODEX_SKILLS_DIR ?= $(CODEX_HOME)/skills
CLAUDE_SKILLS_DIR ?= $(CLAUDE_HOME)/skills

BIN := zig-out/bin/stako
PY_SRC := $(CURDIR)/python
STAKO_SKILL_SRC := $(CURDIR)/skills/stako
CODEX_STAKO_SKILL := $(CODEX_SKILLS_DIR)/stako
CLAUDE_STAKO_SKILL := $(CLAUDE_SKILLS_DIR)/stako

.PHONY: all build install uninstall skill install-python uninstall-python test clean

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

# Install the stdlib-only Python plan API so `import stako` works globally.
# Prefer pipx, then `pip --user`; otherwise drop an editable .pth into the user
# site (the system here is PEP 668 externally-managed with no pip/pipx).
install-python:
	@if command -v pipx >/dev/null 2>&1; then \
		mkdir -p "$(PY_SRC)/stako/prompts" && cp -a prompts/. "$(PY_SRC)/stako/prompts/"; \
		pipx install --force "$(PY_SRC)"; \
	elif $(PYTHON) -m pip --version >/dev/null 2>&1; then \
		mkdir -p "$(PY_SRC)/stako/prompts" && cp -a prompts/. "$(PY_SRC)/stako/prompts/"; \
		$(PYTHON) -m pip install --user --force-reinstall "$(PY_SRC)"; \
	else \
		site=`$(PYTHON) -c 'import site; print(site.getusersitepackages())'`; \
		mkdir -p "$$site"; \
		echo "$(PY_SRC)" > "$$site/stako.pth"; \
		echo "linked stako (editable) via $$site/stako.pth -> $(PY_SRC)"; \
	fi
	@$(PYTHON) -c "import stako; print('stako python', stako.__version__, '| prompts:', ', '.join(stako.prompts.names()))"

uninstall-python:
	@if command -v pipx >/dev/null 2>&1 && pipx list 2>/dev/null | grep -q stako; then pipx uninstall stako; fi
	@site=`$(PYTHON) -c 'import site; print(site.getusersitepackages())'`; rm -f "$$site/stako.pth"
	@echo "removed stako python editable link (if present)"

test:
	$(ZIG) build test

clean:
	rm -rf zig-out .zig-cache python/build python/stako/prompts python/*.egg-info
