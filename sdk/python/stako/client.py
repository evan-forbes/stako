from __future__ import annotations

import hashlib
import http.client
import json
import os
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol


DEFAULT_PORT = 7421
DEFAULT_ROOT = Path.home() / "stako"
NAME_RE = re.compile(r"^[a-z0-9_-]+$")
STAKO_PARAMS_ENV = "STAKO_PARAMS"
_VALID_STAKO_KEYS = frozenset({"root", "port", "host", "stack", "inputs"})
_VALID_INPUT_KEYS = frozenset({"items", "files", "commits", "mode"})


class ApiError(RuntimeError):
    def __init__(self, status: int, path: str, body: bytes):
        self.status = status
        self.path = path
        self.body = body
        detail = body.decode("utf-8", errors="replace")
        super().__init__(f"stako API request failed: {status} {path}: {detail}")


class ParamsError(ValueError):
    """A params TOML was missing, malformed, or carried unexpected keys."""


class Transport(Protocol):
    def request(
        self,
        host: str,
        port: int,
        method: str,
        path: str,
        body: bytes | None,
        headers: dict[str, str],
    ) -> tuple[int, bytes]: ...


class HttpTransport:
    def request(
        self,
        host: str,
        port: int,
        method: str,
        path: str,
        body: bytes | None,
        headers: dict[str, str],
    ) -> tuple[int, bytes]:
        conn = http.client.HTTPConnection(host, port, timeout=30)
        try:
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.read()
        finally:
            conn.close()


class Client:
    def __init__(
        self,
        root: str | Path | None = None,
        port: int | None = None,
        host: str = "127.0.0.1",
        transport: Transport | None = None,
    ):
        self.root = Path(root).expanduser() if root is not None else DEFAULT_ROOT
        self.host = host
        self.port = port if port is not None else self._read_port()
        self.token = self._read_token()
        self.transport = transport or HttpTransport()

    def stack(self, name: str) -> Stack:
        return Stack(self, name)

    def write_prompt(self, rel_path: str, text: str) -> Path:
        # Caller owns returned path. Writes a routine template prompt under
        # <root>/prompts/, refusing paths that escape that directory. Affects
        # future routine appends only — not items already on a stack.
        base = (self.root / "prompts").resolve()
        target = (self.root / "prompts" / rel_path).resolve()
        try:
            target.relative_to(base)
        except ValueError:
            raise ValueError(f"prompt path escapes prompts/: {rel_path!r}") from None
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def post(self, path: str, payload: dict[str, Any] | None = None) -> Any:
        return self.request("POST", path, payload or {})

    def request(
        self, method: str, path: str, payload: dict[str, Any] | None = None
    ) -> Any:
        body = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
        }
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"

        status, raw = self.transport.request(
            self.host, self.port, method, path, body, headers
        )
        if status >= 400:
            raise ApiError(status, path, raw)
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    def _read_port(self) -> int:
        config_path = self.root / "config.toml"
        if not config_path.exists():
            return DEFAULT_PORT
        with config_path.open("rb") as f:
            data = tomllib.load(f)
        return int(data.get("daemon", {}).get("port", DEFAULT_PORT))

    def _read_token(self) -> str:
        token_path = self.root / "state" / "local_token"
        token = token_path.read_text(encoding="utf-8").strip()
        if not token:
            raise ValueError(f"empty stako token: {token_path}")
        return token


class Stack:
    def __init__(self, client: Client, name: str):
        _check_name(name, "stack")
        self.client = client
        self.name = name

    def create(self, config: dict[str, Any] | None = None) -> Stack:
        payload: dict[str, Any] = {"name": self.name}
        if config:
            payload["config"] = config
        self.client.post("/stacks", payload)
        return self

    def add(
        self, routine: Routine, inputs: Inputs | dict[str, Any] | None = None
    ) -> Stack:
        routine.materialize(self.client.root)
        for thread in routine.thread_targets():
            self.client.post(f"/stacks/{self.name}/threads", thread)
        resolved = _inputs_payload(inputs)
        payload = {"inputs": resolved} if resolved else {}
        self.client.post(f"/stacks/{self.name}/routines/{routine.name}", payload)
        return self

    def start(self) -> Stack:
        self.client.post(f"/stacks/{self.name}/resume", {})
        return self

    def get_prompt(self, item_id: str) -> str | None:
        data = self.client.get(f"/stacks/{self.name}/items/{item_id}/prompt")
        return (data or {}).get("prompt")

    def edit_prompt(self, item_id: str, prompt: str) -> Stack:
        # Overwrite a queued item's prompt in place. The daemon rejects
        # non-queued items with a 409.
        self.client.post(
            f"/stacks/{self.name}/items/{item_id}/prompt", {"prompt": prompt}
        )
        return self

    def rerun(self, item_id: str, prompt: str, *, thread_mode: str = "fresh") -> Stack:
        # Fork a finished (or any) item: append a new item with the edited
        # prompt, copying the original's kind/slug/thread and recording lineage
        # via `parents`. The original item and its history are left intact.
        item = self.client.get(f"/stacks/{self.name}/items/{item_id}") or {}
        payload: dict[str, Any] = {
            "kind": item.get("kind", "prompt"),
            "slug": item.get("slug", "rerun"),
            "prompt": prompt,
            "parents": [item_id],
        }
        # thread_mode only applies alongside a thread; a thread-less item reruns
        # as a standalone fresh context.
        thread = item.get("thread")
        if isinstance(thread, dict) and thread.get("name"):
            payload["thread"] = thread["name"]
            payload["thread_mode"] = thread_mode
        self.client.post(f"/stacks/{self.name}/items", payload)
        return self


class Prompt:
    """Prompt text resolved eagerly: files are read and parts joined at construction."""

    SEPARATOR = "\n\n---\n\n"

    def __init__(self, body: str):
        self.body = body

    @classmethod
    def text(cls, text: str) -> Prompt:
        return cls(text)

    @classmethod
    def from_file(cls, path: str | Path) -> Prompt:
        return cls(Path(path).expanduser().read_text(encoding="utf-8"))

    @classmethod
    def combine(cls, *parts: str | Prompt) -> Prompt:
        bodies = [part.body if isinstance(part, Prompt) else part for part in parts]
        return cls(cls.SEPARATOR.join(bodies))

    def render(self) -> str:
        return self.body


@dataclass
class _Step:
    kind: str
    thread: str
    prompt: Prompt | None = None


@dataclass
class _Thread:
    provider: str | None = None
    model: str | None = None
    match: str | None = None


class Routine:
    def __init__(self, name: str | None = None):
        if name is not None:
            _check_name(name, "routine")
        self.name = name
        self._steps: list[_Step] = []
        self._threads: dict[str, _Thread] = {}

    def thread(
        self,
        name: str,
        *,
        provider: str | None = None,
        model: str | None = None,
        match: str | None = None,
    ) -> Routine:
        _check_name(name, "thread")
        if match is not None and match not in {"exact", "compatible", "any"}:
            raise ValueError("thread match must be exact, compatible, or any")
        self._threads[name] = _Thread(provider=provider, model=model, match=match)
        return self

    def prompt(
        self,
        text_or_prompt: str | Prompt,
        *,
        thread: str,
    ) -> Routine:
        _check_name(thread, "thread")
        prompt = (
            text_or_prompt
            if isinstance(text_or_prompt, Prompt)
            else Prompt.text(text_or_prompt)
        )
        self._steps.append(_Step("prompt", thread, prompt))
        return self

    def compact(self, *, thread: str) -> Routine:
        _check_name(thread, "thread")
        self._steps.append(_Step("compact", thread))
        return self

    def materialize(self, root: str | Path) -> Path:
        if not self._steps:
            raise ValueError("routine must contain at least one step")
        root_path = Path(root).expanduser()
        name = self._ensure_name()
        prompt_dir = root_path / "prompts" / "generated" / name
        routine_dir = root_path / "routines"
        prompt_dir.mkdir(parents=True, exist_ok=True)
        routine_dir.mkdir(parents=True, exist_ok=True)

        lines = ["version = 1", f"name = {_toml_string(name)}"]
        for index, step in enumerate(self._steps, start=1):
            lines.append("")
            lines.append("[[step]]")
            lines.append(f"thread = {_toml_string(step.thread)}")
            if step.kind == "prompt":
                if step.prompt is None:
                    raise ValueError("prompt step is missing its prompt")
                prompt_path = prompt_dir / f"step-{index:04d}.md"
                prompt_path.write_text(step.prompt.render(), encoding="utf-8")
                rel = f"../prompts/generated/{name}/{prompt_path.name}"
                lines.append(f"prompts = [{_toml_string(rel)}]")
            elif step.kind == "compact":
                lines.append('command = "compact"')
            else:
                raise ValueError(f"unknown routine step kind: {step.kind}")

        routine_path = routine_dir / f"{name}.toml"
        routine_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return routine_path

    def thread_targets(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for name, thread in self._threads.items():
            target = {
                k: v
                for k, v in {
                    "provider": thread.provider,
                    "model": thread.model,
                    "match": thread.match,
                }.items()
                if v is not None
            }
            if not target:
                continue
            out.append({"name": name, "target": target})
        return out

    def overwrite_prompt(self, root: str | Path, step_index: int, text: str) -> Path:
        # Caller owns returned path. Rewrites this routine's generated step
        # prompt (1-based `step_index`) so the next append uses the new text.
        name = self._ensure_name()
        prompt_dir = Path(root).expanduser() / "prompts" / "generated" / name
        prompt_dir.mkdir(parents=True, exist_ok=True)
        path = prompt_dir / f"step-{step_index:04d}.md"
        path.write_text(text, encoding="utf-8")
        return path

    def _ensure_name(self) -> str:
        if self.name is None:
            digest = hashlib.sha256()
            for name in sorted(self._threads):
                thread = self._threads[name]
                digest.update(name.encode())
                digest.update(b"\0")
                for value in (thread.provider, thread.model, thread.match):
                    if value:
                        digest.update(value.encode())
                    digest.update(b"\0")
            for step in self._steps:
                digest.update(step.kind.encode())
                digest.update(b"\0")
                digest.update(step.thread.encode())
                digest.update(b"\0")
                if step.prompt is not None:
                    digest.update(step.prompt.render().encode())
                digest.update(b"\0")
            self.name = f"routine-{digest.hexdigest()[:12]}"
        return self.name


@dataclass
class Inputs:
    """Context registered on queued work: prior items, files, and commits.

    Mirrors the daemon's `inputs` table. `mode` is "append" or "prepend"
    (None leaves the daemon default).
    """

    items: list[str] = field(default_factory=list)
    files: list[str] = field(default_factory=list)
    commits: list[str] = field(default_factory=list)
    mode: str | None = None

    def as_payload(self) -> dict[str, Any]:
        # Caller owns returned dict. Emits only the fields that were set, so the
        # daemon receives an empty object instead of empty arrays when unused.
        payload: dict[str, Any] = {}
        if self.items:
            payload["items"] = list(self.items)
        if self.files:
            payload["files"] = list(self.files)
        if self.commits:
            payload["commits"] = list(self.commits)
        if self.mode is not None:
            payload["mode"] = self.mode
        return payload


@dataclass
class StakoParams:
    """The typed, SDK-validated half of a params TOML's `[stako]` table."""

    root: str | None = None
    port: int | None = None
    host: str = "127.0.0.1"
    stack: str | None = None
    inputs: Inputs = field(default_factory=Inputs)


class Params:
    """A script's parsed params TOML.

    The file has exactly two optional tables: `[stako]`, whose keys are typed
    and validated into `self.stako`, and `[params]`, the script's own free-form
    values, exposed untouched as `self.params`. Any other top-level key is an
    error. This is the convention scripts use instead of building their own CLI.
    """

    def __init__(self, stako: StakoParams, params: dict[str, Any]):
        self.stako = stako
        self.params = params

    @classmethod
    def load(
        cls,
        path: str | Path | None = None,
        *,
        argv: list[str] | None = None,
        environ: dict[str, str] | None = None,
    ) -> Params:
        # Resolve the file from (in order) `path`, the first CLI argument, then
        # $STAKO_PARAMS — no argparse needed. `argv`/`environ` are injectable
        # for tests.
        resolved = cls._resolve_path(path, argv, environ)
        try:
            with resolved.open("rb") as f:
                data = tomllib.load(f)
        except FileNotFoundError:
            raise ParamsError(f"params file not found: {resolved}") from None
        except tomllib.TOMLDecodeError as e:
            raise ParamsError(f"invalid TOML in {resolved}: {e}") from e
        return cls.from_dict(data, source=resolved)

    @classmethod
    def from_dict(
        cls, data: dict[str, Any], *, source: Path | None = None
    ) -> Params:
        where = f" in {source}" if source is not None else ""
        unexpected = set(data) - {"stako", "params"}
        if unexpected:
            keys = ", ".join(sorted(unexpected))
            raise ParamsError(
                f"unexpected top-level key(s){where}: {keys}; put Stako fields "
                "under [stako] and script values under [params]"
            )
        params = data.get("params", {})
        if not isinstance(params, dict):
            raise ParamsError(f"[params]{where} must be a table")
        return cls(cls._parse_stako(data.get("stako", {}), where), params)

    def client(self, *, transport: Transport | None = None) -> Client:
        return Client(
            root=self.stako.root,
            port=self.stako.port,
            host=self.stako.host,
            transport=transport,
        )

    def target_stack(self, client: Client | None = None) -> Stack:
        if not self.stako.stack:
            raise ParamsError("[stako] has no stack; cannot resolve target stack")
        return (client or self.client()).stack(self.stako.stack)

    def get(self, key: str, default: Any = None) -> Any:
        # Convenience read of a `[params]` value.
        return self.params.get(key, default)

    @staticmethod
    def _resolve_path(
        path: str | Path | None,
        argv: list[str] | None,
        environ: dict[str, str] | None,
    ) -> Path:
        if path is not None:
            return Path(path).expanduser()
        argv = sys.argv if argv is None else argv
        if len(argv) > 1 and argv[1]:
            return Path(argv[1]).expanduser()
        env = os.environ if environ is None else environ
        env_path = env.get(STAKO_PARAMS_ENV)
        if env_path:
            return Path(env_path).expanduser()
        raise ParamsError(
            "no params file: pass its path as the first argument or set "
            f"${STAKO_PARAMS_ENV}"
        )

    @staticmethod
    def _parse_stako(raw: Any, where: str) -> StakoParams:
        if not isinstance(raw, dict):
            raise ParamsError(f"[stako]{where} must be a table")
        unexpected = set(raw) - _VALID_STAKO_KEYS
        if unexpected:
            keys = ", ".join(sorted(unexpected))
            raise ParamsError(f"unknown [stako] key(s){where}: {keys}")
        stako = StakoParams()
        if "root" in raw:
            stako.root = _expect_str(raw["root"], "stako.root", where)
        if "host" in raw:
            stako.host = _expect_str(raw["host"], "stako.host", where)
        if "stack" in raw:
            name = _expect_str(raw["stack"], "stako.stack", where)
            _check_name(name, "stack")
            stako.stack = name
        if "port" in raw:
            port = raw["port"]
            if not isinstance(port, int) or isinstance(port, bool):
                raise ParamsError(f"stako.port{where} must be an integer")
            stako.port = port
        if "inputs" in raw:
            stako.inputs = Params._parse_inputs(raw["inputs"], where)
        return stako

    @staticmethod
    def _parse_inputs(raw: Any, where: str) -> Inputs:
        if not isinstance(raw, dict):
            raise ParamsError(f"[stako.inputs]{where} must be a table")
        unexpected = set(raw) - _VALID_INPUT_KEYS
        if unexpected:
            keys = ", ".join(sorted(unexpected))
            raise ParamsError(f"unknown [stako.inputs] key(s){where}: {keys}")
        inputs = Inputs()
        for key in ("items", "files", "commits"):
            if key in raw:
                value = _expect_str_list(raw[key], f"stako.inputs.{key}", where)
                setattr(inputs, key, value)
        if "mode" in raw:
            mode = _expect_str(raw["mode"], "stako.inputs.mode", where)
            if mode not in {"append", "prepend"}:
                raise ParamsError(
                    f"stako.inputs.mode{where} must be 'append' or 'prepend'"
                )
            inputs.mode = mode
        return inputs


def _inputs_payload(inputs: Inputs | dict[str, Any] | None) -> dict[str, Any] | None:
    if inputs is None:
        return None
    if isinstance(inputs, Inputs):
        return inputs.as_payload() or None
    return inputs or None


def _expect_str(value: Any, field_name: str, where: str) -> str:
    if not isinstance(value, str):
        raise ParamsError(f"{field_name}{where} must be a string")
    return value


def _expect_str_list(value: Any, field_name: str, where: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ParamsError(f"{field_name}{where} must be an array of strings")
    return list(value)


def _check_name(name: str, label: str) -> None:
    if not NAME_RE.fullmatch(name):
        raise ValueError(f"invalid {label} name: {name!r}")


def _toml_string(value: str) -> str:
    return json.dumps(value)
