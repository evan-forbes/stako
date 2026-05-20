from __future__ import annotations

import hashlib
import http.client
import json
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol


DEFAULT_PORT = 7421
DEFAULT_ROOT = Path.home() / "stako"
NAME_RE = re.compile(r"^[a-z0-9_-]+$")


class ApiError(RuntimeError):
    def __init__(self, status: int, path: str, body: bytes):
        self.status = status
        self.path = path
        self.body = body
        detail = body.decode("utf-8", errors="replace")
        super().__init__(f"stako API request failed: {status} {path}: {detail}")


class Transport(Protocol):
    def request(
        self,
        host: str,
        port: int,
        method: str,
        path: str,
        body: bytes | None,
        headers: dict[str, str],
    ) -> tuple[int, bytes]:
        ...


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

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def post(self, path: str, payload: dict[str, Any] | None = None) -> Any:
        return self.request("POST", path, payload or {})

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
        body = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
        }
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"

        status, raw = self.transport.request(self.host, self.port, method, path, body, headers)
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

    def add(self, routine: Routine, inputs: dict[str, Any] | None = None) -> Stack:
        routine.materialize(self.client.root)
        for thread in routine.thread_targets():
            self.client.post(f"/stacks/{self.name}/threads", thread)
        payload = {"inputs": inputs} if inputs else {}
        self.client.post(f"/stacks/{self.name}/routines/{routine.name}", payload)
        return self

    def start(self) -> Stack:
        self.client.post(f"/stacks/{self.name}/resume", {})
        return self


class Prompt:
    def __init__(self, kind: str, value: str | Path | list[Prompt]):
        self.kind = kind
        self.value = value

    @classmethod
    def text(cls, text: str) -> Prompt:
        return cls("text", text)

    @classmethod
    def from_file(cls, path: str | Path) -> Prompt:
        return cls("file", Path(path).expanduser())

    @classmethod
    def combine(cls, *parts: str | Prompt) -> Prompt:
        prompts = [p if isinstance(p, Prompt) else Prompt.text(p) for p in parts]
        return cls("combine", prompts)

    def render(self) -> str:
        if self.kind == "text":
            return str(self.value)
        if self.kind == "file":
            return Path(self.value).read_text(encoding="utf-8")
        if self.kind == "combine":
            return "\n\n---\n\n".join(part.render() for part in self.value)  # type: ignore[union-attr]
        raise ValueError(f"unknown prompt kind: {self.kind}")

    def fingerprint(self) -> str:
        return self.render()


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
        prompt = text_or_prompt if isinstance(text_or_prompt, Prompt) else Prompt.text(text_or_prompt)
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
                prompt_path = prompt_dir / f"step-{index:04d}.md"
                prompt_path.write_text(step.prompt.render(), encoding="utf-8")  # type: ignore[union-attr]
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
                    digest.update(step.prompt.fingerprint().encode())
                digest.update(b"\0")
            self.name = f"routine-{digest.hexdigest()[:12]}"
        return self.name


def _check_name(name: str, label: str) -> None:
    if not NAME_RE.fullmatch(name):
        raise ValueError(f"invalid {label} name: {name!r}")


def _toml_string(value: str) -> str:
    return json.dumps(value)
