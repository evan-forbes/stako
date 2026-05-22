import json
import tempfile
import unittest
from pathlib import Path

from stako import (
    Client,
    Inputs,
    Params,
    ParamsError,
    Prompt,
    Routine,
    Stack,
)


class FakeTransport:
    def __init__(self):
        self.calls = []

    def request(self, host, port, method, path, body, headers):
        payload = json.loads(body.decode("utf-8")) if body else None
        self.calls.append(
            {
                "host": host,
                "port": port,
                "method": method,
                "path": path,
                "body": payload,
                "headers": dict(headers),
            }
        )
        return 200, b'{"ok":true}'


class RoutingTransport:
    """Returns a per-path JSON body so GET-then-POST flows can be exercised."""

    def __init__(self, bodies):
        self.bodies = bodies
        self.calls = []

    def request(self, host, port, method, path, body, headers):
        payload = json.loads(body.decode("utf-8")) if body else None
        self.calls.append({"method": method, "path": path, "body": payload})
        return 200, self.bodies.get(path, b'{"ok":true}')


class ClientTests(unittest.TestCase):
    def make_root(self):
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "state").mkdir()
        (root / "state" / "local_token").write_text("tok123\n", encoding="utf-8")
        (root / "config.toml").write_text("[daemon]\nport = 8123\n", encoding="utf-8")
        return tmp, root

    def test_loads_port_token_and_sends_authorized_json(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        transport = FakeTransport()
        client = Client(root=root, transport=transport)

        self.assertEqual(client.port, 8123)
        client.post("/stacks", {"name": "demo"})

        self.assertEqual(transport.calls[0]["host"], "127.0.0.1")
        self.assertEqual(transport.calls[0]["port"], 8123)
        self.assertEqual(transport.calls[0]["method"], "POST")
        self.assertEqual(transport.calls[0]["path"], "/stacks")
        self.assertEqual(transport.calls[0]["body"], {"name": "demo"})
        self.assertEqual(
            transport.calls[0]["headers"]["Authorization"], "Bearer tok123"
        )

    def test_prompt_combine_and_from_file(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        src = root / "source.md"
        src.write_text("second", encoding="utf-8")

        prompt = Prompt.combine("first", Prompt.from_file(src))

        self.assertEqual(prompt.render(), "first\n\n---\n\nsecond")

    def test_stack_flow_materializes_routine_and_uses_daemon_order(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        transport = FakeTransport()
        client = Client(root=root, transport=transport)
        routine = (
            Routine("ship-it")
            .thread("builder", provider="openai", model="gpt-5")
            .prompt("Implement the change.", thread="builder")
            .compact(thread="builder")
        )

        Stack(client, "demo").create().add(routine).start()

        prompt_path = root / "prompts" / "generated" / "ship-it" / "step-0001.md"
        routine_path = root / "routines" / "ship-it.toml"
        self.assertEqual(
            prompt_path.read_text(encoding="utf-8"), "Implement the change."
        )
        routine_text = routine_path.read_text(encoding="utf-8")
        self.assertIn('name = "ship-it"', routine_text)
        self.assertIn(
            'prompts = ["../prompts/generated/ship-it/step-0001.md"]', routine_text
        )
        self.assertIn('command = "compact"', routine_text)

        self.assertEqual(
            [(c["method"], c["path"], c["body"]) for c in transport.calls],
            [
                ("POST", "/stacks", {"name": "demo"}),
                (
                    "POST",
                    "/stacks/demo/threads",
                    {
                        "name": "builder",
                        "target": {"provider": "openai", "model": "gpt-5"},
                    },
                ),
                ("POST", "/stacks/demo/routines/ship-it", {}),
                ("POST", "/stacks/demo/resume", {}),
            ],
        )

    def test_anonymous_routine_gets_stable_generated_name(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        routine = (
            Routine()
            .thread("builder", provider="openai")
            .prompt(Prompt.text("hello"), thread="builder")
        )

        first = routine.materialize(root)
        second = routine.materialize(root)

        self.assertEqual(first, second)
        self.assertRegex(first.name, r"^routine-[0-9a-f]{12}\.toml$")

    def test_edit_prompt_posts_prompt_body(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        transport = FakeTransport()
        client = Client(root=root, transport=transport)

        client.stack("demo").edit_prompt("0001", "rewritten")

        self.assertEqual(
            (
                transport.calls[0]["method"],
                transport.calls[0]["path"],
                transport.calls[0]["body"],
            ),
            ("POST", "/stacks/demo/items/0001/prompt", {"prompt": "rewritten"}),
        )

    def test_get_prompt_returns_field(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        transport = RoutingTransport(
            {"/stacks/demo/items/0001/prompt": b'{"prompt":"hello"}'}
        )
        client = Client(root=root, transport=transport)

        self.assertEqual(client.stack("demo").get_prompt("0001"), "hello")

    def test_rerun_appends_with_parents_and_thread(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        transport = RoutingTransport(
            {
                "/stacks/demo/items/0001": b'{"kind":"prompt","slug":"impl","thread":{"name":"builder","mode":"resume"}}'
            }
        )
        client = Client(root=root, transport=transport)

        client.stack("demo").rerun("0001", "try again")

        post = transport.calls[-1]
        self.assertEqual((post["method"], post["path"]), ("POST", "/stacks/demo/items"))
        self.assertEqual(
            post["body"],
            {
                "kind": "prompt",
                "slug": "impl",
                "prompt": "try again",
                "parents": ["0001"],
                "thread_mode": "fresh",
                "thread": "builder",
            },
        )

    def test_write_prompt_writes_under_prompts_and_rejects_escape(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        (root / "state" / "local_token").write_text("tok123\n", encoding="utf-8")
        client = Client(root=root, transport=FakeTransport())

        path = client.write_prompt("rate-limiter/impl.md", "do the thing")
        self.assertEqual(path.read_text(encoding="utf-8"), "do the thing")
        self.assertTrue(str(path).endswith("prompts/rate-limiter/impl.md"))

        with self.assertRaises(ValueError):
            client.write_prompt("../escape.md", "nope")

    def test_overwrite_prompt_writes_generated_step(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        routine = Routine("ship-it").thread("builder").prompt("first", thread="builder")

        path = routine.overwrite_prompt(root, 1, "second")

        self.assertEqual(path.read_text(encoding="utf-8"), "second")
        self.assertEqual(
            path, root / "prompts" / "generated" / "ship-it" / "step-0001.md"
        )


class ParamsTests(unittest.TestCase):
    PARAMS_TOML = """
[stako]
root = "~/stako"
port = 8123
stack = "add-rate-limiter"

[stako.inputs]
files = ["docs/spec.md"]
items = ["0001"]
mode = "prepend"

[params]
target_module = "ratelimit"
max_retries = 3
"""

    def write_params(self, text: str) -> Path:
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".toml", delete=False, encoding="utf-8"
        )
        tmp.write(text)
        tmp.close()
        path = Path(tmp.name)
        self.addCleanup(path.unlink)
        return path

    def test_load_parses_typed_stako_and_free_form_params(self):
        path = self.write_params(self.PARAMS_TOML)

        params = Params.load(path)

        self.assertEqual(params.stako.root, "~/stako")
        self.assertEqual(params.stako.port, 8123)
        self.assertEqual(params.stako.stack, "add-rate-limiter")
        self.assertEqual(params.stako.inputs.files, ["docs/spec.md"])
        self.assertEqual(params.stako.inputs.items, ["0001"])
        self.assertEqual(params.stako.inputs.mode, "prepend")
        self.assertEqual(params.params["target_module"], "ratelimit")
        self.assertEqual(params.get("max_retries"), 3)
        self.assertIsNone(params.get("missing"))

    def test_resolves_path_from_argv_then_env(self):
        path = self.write_params(self.PARAMS_TOML)

        from_argv = Params.load(argv=["script.py", str(path)])
        self.assertEqual(from_argv.stako.stack, "add-rate-limiter")

        from_env = Params.load(argv=["script.py"], environ={"STAKO_PARAMS": str(path)})
        self.assertEqual(from_env.stako.stack, "add-rate-limiter")

    def test_missing_path_raises(self):
        with self.assertRaises(ParamsError):
            Params.load(argv=["script.py"], environ={})

    def test_rejects_unexpected_top_level_key(self):
        with self.assertRaises(ParamsError):
            Params.from_dict({"stako": {}, "extra": {}})

    def test_rejects_unknown_stako_key(self):
        with self.assertRaises(ParamsError):
            Params.from_dict({"stako": {"prot": 9000}})

    def test_rejects_bad_input_mode_and_bad_types(self):
        with self.assertRaises(ParamsError):
            Params.from_dict({"stako": {"inputs": {"mode": "sideways"}}})
        with self.assertRaises(ParamsError):
            Params.from_dict({"stako": {"port": "8123"}})
        with self.assertRaises(ParamsError):
            Params.from_dict({"stako": {"inputs": {"files": "docs/spec.md"}}})

    def test_inputs_as_payload_omits_empty_fields(self):
        self.assertEqual(Inputs().as_payload(), {})
        self.assertEqual(
            Inputs(files=["a.md"], mode="append").as_payload(),
            {"files": ["a.md"], "mode": "append"},
        )

    def test_client_and_target_stack_built_from_params(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "state").mkdir()
        (root / "state" / "local_token").write_text("tok123\n", encoding="utf-8")
        (root / "config.toml").write_text("[daemon]\nport = 9001\n", encoding="utf-8")

        params = Params.from_dict({"stako": {"root": str(root), "stack": "demo"}})
        transport = FakeTransport()
        stack = params.target_stack(params.client(transport=transport))

        self.assertEqual(stack.name, "demo")
        self.assertEqual(stack.client.port, 9001)

    def test_target_stack_without_stack_raises(self):
        with self.assertRaises(ParamsError):
            Params.from_dict({"stako": {}}).target_stack()

    def test_add_accepts_typed_inputs(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        transport = FakeTransport()
        client = Client(root=root, transport=transport)
        routine = Routine("ship-it").thread("builder").prompt("go", thread="builder")

        Stack(client, "demo").create().add(
            routine, inputs=Inputs(items=["0001"], mode="append")
        )

        queue_call = next(
            c for c in transport.calls if c["path"] == "/stacks/demo/routines/ship-it"
        )
        self.assertEqual(
            queue_call["body"], {"inputs": {"items": ["0001"], "mode": "append"}}
        )

    def make_root(self):
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "state").mkdir()
        (root / "state" / "local_token").write_text("tok123\n", encoding="utf-8")
        (root / "config.toml").write_text("[daemon]\nport = 8123\n", encoding="utf-8")
        return tmp, root


if __name__ == "__main__":
    unittest.main()
