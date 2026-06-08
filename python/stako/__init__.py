"""stako — emit a `plan.toml` graph from concise Python.

Stdlib only, Python 3.9+. The library owns no runtime. A :class:`Stack`
collects threads and prompt nodes, derives ``blocked_by`` from handle/cursor
data flow, writes one ``plan.toml``, and shells out to the ``stako`` binary.
This is the same graph a hand-authored folder uses; see
``09_unified_authoring_model.md``.

Typical use::

    from stako import Stack, prompts

    with Stack("review-loop", cwd="~/src/myrepo") as s:
        impl    = s.thread("impl",    command="codex")
        quality = s.thread("quality", command="claude")
        checker = s.thread("checker", command="claude")

        for task in s.glob("plans/*.md"):
            i = impl(prompts.implementer, task, new=True)
            q = quality(prompts.code_quality, i)
            checker(prompts.checker, q)

The bundled prompt library is reached by nickname through :data:`prompts`
(``prompts.implementer``, ``prompts.code_quality``, ...); each resolves to a
reusable body that becomes a node's ``use`` path.
"""

import glob as _glob
import os
import shlex
import subprocess
import tempfile

__all__ = ["Stack", "Thread", "Handle", "Cursor", "PromptRef", "prompt", "prompts", "StakoError"]
__version__ = "0.1.0"


class StakoError(Exception):
    """Authoring error raised before anything is queued."""


# ---------- prompt library ----------


def _library_dir():
    """Directory holding the reusable prompt bodies, by resolution order:
    ``$STAKO_PROMPTS``, a bundled ``prompts/`` beside this package (installed
    wheels), then the repo-root ``prompts/`` (editable / in-tree)."""
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (
        os.environ.get("STAKO_PROMPTS"),
        os.path.join(here, "prompts"),
        os.path.join(os.path.dirname(os.path.dirname(here)), "prompts"),
    ):
        if cand and os.path.isdir(cand):
            return cand
    raise StakoError("cannot locate the stako prompt library; set $STAKO_PROMPTS")


class PromptRef:
    """A reusable prompt body referenced by absolute path; a node's ``use``."""

    __slots__ = ("path",)

    def __init__(self, path):
        self.path = os.path.abspath(os.path.expanduser(path))

    def __repr__(self):
        return "PromptRef({!r})".format(self.path)


def prompt(path):
    """Reference an arbitrary prompt body file. Missing files fail here."""
    p = os.path.abspath(os.path.expanduser(path))
    if not os.path.isfile(p):
        raise StakoError("prompt file not found: {}".format(path))
    return PromptRef(p)


class _Prompts:
    """The nicknamed prompt library: ``prompts.implementer`` -> PromptRef."""

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return self[name]

    def __getitem__(self, name):
        path = os.path.join(_library_dir(), "{}.md".format(name))
        if not os.path.isfile(path):
            raise StakoError(
                "no prompt nicknamed {!r}; available: {}".format(name, ", ".join(self.names()))
            )
        return PromptRef(path)

    def names(self):
        d = _library_dir()
        names = []
        for root, dirs, files in os.walk(d):
            dirs[:] = sorted(name for name in dirs if not name.startswith("."))
            rel_root = os.path.relpath(root, d)
            prefix = "" if rel_root == "." else rel_root + "/"
            for file_name in sorted(files):
                if not file_name.endswith(".md") or file_name == "README.md":
                    continue
                names.append(prefix + file_name[:-3])
        return names


prompts = _Prompts()


# ---------- graph nodes ----------


class _Node:
    __slots__ = ("name", "thread", "use", "with_", "body", "action", "blocked_by", "raw")

    def __init__(self, name, thread, use, with_, body, action, blocked_by, raw):
        self.name = name
        self.thread = thread
        self.use = use
        self.with_ = with_
        self.body = body
        self.action = action
        self.blocked_by = blocked_by
        self.raw = raw


class Handle:
    """The value a thread call returns; pass it to a later call to make that
    call ``blocked_by`` this node (and receive its ``result.md``)."""

    __slots__ = ("node",)

    def __init__(self, node):
        self.node = node


class Cursor:
    """A first-class dependency cursor. It carries zero or more tail handles and
    emits only ordinary ``blocked_by`` entries when passed to a thread call."""

    __slots__ = ("_deps",)

    def __init__(self, deps=()):
        self._deps = tuple(deps)

    @property
    def empty(self):
        return len(self._deps) == 0

    def advance(self, *deps):
        """Return a cursor whose tail is exactly ``deps``."""
        return Cursor(_deps_from(deps))

    def join(self, *deps):
        """Return a cursor combining this cursor's deps with ``deps``."""
        return Cursor(_dedupe(list(self._deps) + _deps_from(deps)))


class Thread:
    """A long-lived agent session. Calling it appends one prompt node."""

    __slots__ = ("_stack", "name", "command", "default")

    def __init__(self, stack, name, command, default):
        self._stack = stack
        self.name = name
        self.command = command
        self.default = default

    def __call__(
        self,
        *args,
        use=None,
        body=None,
        action=None,
        new=False,
        clear=False,
        compact=False,
        raw=False,
        name=None,
        label=None,
    ):
        return self._stack._add(
            self, args, use, body, action, new, clear, compact, raw, name, label
        )


class _Step:
    def __init__(self, stack):
        self._stack = stack

    def __enter__(self):
        self._stack._step_enter()
        return self

    def __exit__(self, *exc):
        self._stack._step_exit()
        return False


# ---------- stack ----------


class Stack:
    """Collect threads and prompt nodes, then emit ``plan.toml`` on clean exit.

    On a clean ``with`` exit the plan is written and handed to ``stako new``; an
    exception inside the block writes nothing. ``dry_run=True`` writes the files
    and prints the exact command without queueing.
    """

    def __init__(self, name, cwd=None, root=None, out=None, dry_run=False, create=True):
        self.name = name
        self.cwd = os.path.abspath(os.path.expanduser(cwd)) if cwd else None
        self.root = os.path.abspath(os.path.expanduser(root)) if root else None
        self.out = os.path.abspath(os.path.expanduser(out)) if out else None
        self.dry_run = dry_run
        self.create = create
        self._threads = []
        self._thread_names = set()
        self._nodes = []
        self._node_names = set()
        self._counter = 0
        # step barriers: nodes of the previous step gate every node of this one.
        self._prev_step = []
        self._cur_step = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self._materialize()
        return False

    # -- declarations --

    def thread(self, name, command="claude", default=None):
        if name in self._thread_names:
            raise StakoError("thread already declared: {}".format(name))
        if isinstance(default, PromptRef):
            default = _read(default.path)
        t = Thread(self, name, command, default)
        self._threads.append(t)
        self._thread_names.add(name)
        return t

    def glob(self, pattern):
        """Sorted absolute paths matching ``pattern`` from the current directory."""
        return [os.path.abspath(m) for m in sorted(_glob.glob(os.path.expanduser(pattern)))]

    def step(self):
        return _Step(self)

    def cursor(self, *deps):
        return Cursor(_deps_from(deps))

    # -- internals --

    def _step_enter(self):
        if self._cur_step is not None:
            raise StakoError("steps cannot be nested")
        self._cur_step = []

    def _step_exit(self):
        self._prev_step = self._cur_step
        self._cur_step = None

    def _add(self, thread, args, use, body, action, new, clear, compact, raw, name, label):
        action = _resolve_action(action, new, clear, compact)

        with_ = []
        blocked = []
        for a in args:
            if isinstance(a, Handle):
                blocked.append(a.node.name)
            elif isinstance(a, Cursor):
                blocked.extend(a._deps)
            elif isinstance(a, PromptRef):
                if use is None:
                    use = a.path
                else:
                    with_.append(a.path)
            elif isinstance(a, str):
                with_.append(_path_or_literal(a))
            else:
                raise StakoError("unsupported call argument: {!r}".format(a))

        if isinstance(use, PromptRef):
            use = use.path
        elif isinstance(use, str):
            p = os.path.abspath(os.path.expanduser(use))
            if not os.path.isfile(p):
                raise StakoError("use file not found: {}".format(use))
            use = p

        if self._cur_step is not None:
            blocked.extend(self._prev_step)
        blocked = _dedupe(blocked)

        node_name = _sanitize(name or "{:03d}-{}".format(self._next(), thread.name))
        if label:
            node_name = _sanitize("{}-{}".format(node_name, label))
        if node_name in self._node_names:
            raise StakoError("duplicate node name: {}".format(node_name))
        self._node_names.add(node_name)

        node = _Node(node_name, thread.name, use, with_, body, action, blocked, raw)
        self._nodes.append(node)
        if self._cur_step is not None:
            self._cur_step.append(node_name)
        return Handle(node)

    def _next(self):
        self._counter += 10
        return self._counter

    # -- emission --

    def _materialize(self):
        if not self._threads:
            raise StakoError("stack has no threads")
        text = self._render()
        out_dir = self.out or tempfile.mkdtemp(prefix="stako-plan-")
        os.makedirs(out_dir, exist_ok=True)
        plan_path = os.path.join(out_dir, "plan.toml")
        with open(plan_path, "w", encoding="utf-8") as fh:
            fh.write(text)

        argv = self._argv(out_dir)
        if self.dry_run:
            print("wrote {}".format(plan_path))
            print(" ".join(shlex.quote(a) for a in argv))
            return
        if not self.create:
            raise StakoError(
                "create=False (merge into an existing stack) needs `stako add`, "
                "which this build does not provide yet; wrote {}".format(plan_path)
            )
        try:
            subprocess.run(argv, check=True)
        finally:
            if self.out is None:
                _rmtree(out_dir)

    def _argv(self, out_dir):
        bin_ = os.environ.get("STAKO_BIN", "stako")
        return [bin_, "new", out_dir]

    def _render(self):
        lines = ["name = {}".format(_tstr(self.name))]
        if self.cwd:
            lines.append("cwd = {}".format(_tstr(self.cwd)))
        if self.root:
            lines.append("root = {}".format(_tstr(self.root)))
        for t in self._threads:
            lines.append("")
            lines.append("[[thread]]")
            lines.append("name = {}".format(_tstr(t.name)))
            lines.append("command = {}".format(_tstr(t.command)))
            if t.default:
                lines.append("default = {}".format(_tstr(t.default)))
        for n in self._nodes:
            lines.append("")
            lines.append("[[prompt]]")
            lines.append("name = {}".format(_tstr(n.name)))
            lines.append("thread = {}".format(_tstr(n.thread)))
            if n.action:
                lines.append("action = {}".format(_tstr(n.action)))
            if n.use:
                lines.append("use = {}".format(_tstr(n.use)))
            if n.with_:
                lines.append("with = {}".format(_tarray(n.with_)))
            if n.body:
                lines.append("body = {}".format(_tstr(n.body)))
            if n.blocked_by:
                lines.append("blocked_by = {}".format(_tarray(n.blocked_by)))
            if n.raw:
                lines.append("raw = true")
        return "\n".join(lines) + "\n"


# ---------- helpers ----------


def _resolve_action(action, new, clear, compact):
    chosen = [n for n, f in (("new", new), ("clear", clear), ("compact", compact)) if f]
    if action:
        chosen.append(action)
    if len(chosen) > 1:
        raise StakoError("at most one action per call, got: {}".format(", ".join(chosen)))
    return chosen[0] if chosen else None


def _dedupe(items):
    seen = set()
    out = []
    for it in items:
        if it not in seen:
            seen.add(it)
            out.append(it)
    return out


def _deps_from(items):
    out = []
    for item in items:
        if isinstance(item, Handle):
            out.append(item.node.name)
        elif isinstance(item, Cursor):
            out.extend(item._deps)
        else:
            raise StakoError("cursor dependency must be a Handle or Cursor: {!r}".format(item))
    return _dedupe(out)


def _path_or_literal(s):
    p = os.path.expanduser(s)
    return os.path.abspath(p) if os.path.isfile(p) else s


def _sanitize(name):
    out = []
    for ch in name:
        c = ch.lower()
        if ("a" <= c <= "z") or ("0" <= c <= "9") or c in "-_":
            out.append(c)
        else:
            out.append("-")
    s = "".join(out).strip("-")
    if not s:
        raise StakoError("node name sanitized to empty: {!r}".format(name))
    return s


def _read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


def _tstr(s):
    """A TOML basic string matching the stako parser's escape set."""
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _tarray(items):
    return "[" + ", ".join(_tstr(i) for i in items) + "]"


def _rmtree(path):
    import shutil

    shutil.rmtree(path, ignore_errors=True)
