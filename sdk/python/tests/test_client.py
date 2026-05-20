import json
import tempfile
import unittest
from pathlib import Path

from stako import Client, Prompt, Routine, Stack


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
        self.assertEqual(transport.calls[0]["headers"]["Authorization"], "Bearer tok123")

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
        self.assertEqual(prompt_path.read_text(encoding="utf-8"), "Implement the change.")
        routine_text = routine_path.read_text(encoding="utf-8")
        self.assertIn('name = "ship-it"', routine_text)
        self.assertIn('prompts = ["../prompts/generated/ship-it/step-0001.md"]', routine_text)
        self.assertIn('command = "compact"', routine_text)

        self.assertEqual(
            [(c["method"], c["path"], c["body"]) for c in transport.calls],
            [
                ("POST", "/stacks", {"name": "demo"}),
                (
                    "POST",
                    "/stacks/demo/threads",
                    {"name": "builder", "target": {"provider": "openai", "model": "gpt-5"}},
                ),
                ("POST", "/stacks/demo/routines/ship-it", {}),
                ("POST", "/stacks/demo/resume", {}),
            ],
        )

    def test_anonymous_routine_gets_stable_generated_name(self):
        tmp, root = self.make_root()
        self.addCleanup(tmp.cleanup)
        routine = Routine().thread("builder", provider="openai").prompt(Prompt.text("hello"), thread="builder")

        first = routine.materialize(root)
        second = routine.materialize(root)

        self.assertEqual(first, second)
        self.assertRegex(first.name, r"^routine-[0-9a-f]{12}\.toml$")


if __name__ == "__main__":
    unittest.main()
