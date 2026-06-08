"""Tests for the stako plan emitter. Stdlib unittest, no third-party deps.

Run: python3 -m unittest discover -s python/tests
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import stako  # noqa: E402
from stako import Stack, prompt, prompts, Cursor, StakoError  # noqa: E402


def render(build, **kw):
    """Run a builder against a Stack in dry_run and return the plan.toml text."""
    out = tempfile.mkdtemp(prefix="stako-test-")
    with Stack("t", out=out, dry_run=True, **kw) as s:
        build(s)
    with open(os.path.join(out, "plan.toml"), encoding="utf-8") as fh:
        return fh.read()


class HandleFlow(unittest.TestCase):
    def test_handle_arg_becomes_blocked_by(self):
        def build(s):
            a = s.thread("a", command="codex")
            b = s.thread("b", command="claude")
            h = a(body="do")
            b(h, body="review")

        text = render(build)
        self.assertIn('name = "020-b"', text)
        self.assertIn('blocked_by = ["010-a"]', text)

    def test_consecutive_same_thread_no_hidden_edge(self):
        def build(s):
            a = s.thread("a", command="codex")
            a(body="one")
            a(body="two")

        text = render(build)
        # The second node names no blocker: thread occupancy orders them.
        self.assertNotIn("blocked_by", text)

    def test_actions_are_per_call(self):
        def build(s):
            a = s.thread("a", command="codex")
            a(body="x", new=True)
            a(body="y", compact=True)

        text = render(build)
        self.assertIn('action = "new"', text)
        self.assertIn('action = "compact"', text)

    def test_multiple_actions_rejected(self):
        with self.assertRaises(StakoError):
            with Stack("t", out=tempfile.mkdtemp(), dry_run=True) as s:
                a = s.thread("a", command="codex")
                a(body="x", new=True, compact=True)


class Steps(unittest.TestCase):
    def test_step_barrier_blocks_on_all_previous_and_dedupes(self):
        def build(s):
            impl = s.thread("impl", command="codex")
            rev = s.thread("rev", command="claude")
            with s.step():
                a = impl(body="A")
                b = impl(body="B")
            with s.step():
                rev(a, b, body="review")  # handles + barrier name the same nodes

        text = render(build)
        # Deduped: each blocker appears once despite handle + barrier overlap.
        self.assertIn('blocked_by = ["010-impl", "020-impl"]', text)
        self.assertEqual(text.count('"010-impl"'), 2)  # node decl + one blocker ref


class Cursors(unittest.TestCase):
    def test_cursor_arg_becomes_blocked_by(self):
        def build(s):
            a = s.thread("a", command="codex")
            b = s.thread("b", command="claude")
            h = a(body="do")
            b(s.cursor(h), body="review")

        text = render(build)
        self.assertIn('blocked_by = ["010-a"]', text)

    def test_cursor_advance_uses_only_new_tail(self):
        def build(s):
            a = s.thread("a", command="codex")
            c = s.cursor()
            first = a(c, body="one", new=c.empty)
            c = c.advance(first)
            second = a(c, body="two")
            c = c.advance(second)
            a(c, body="three")

        text = render(build)
        self.assertIn('name = "020-a"', text)
        self.assertIn('blocked_by = ["010-a"]', text)
        self.assertIn('name = "030-a"', text)
        self.assertIn('blocked_by = ["020-a"]', text)
        self.assertNotIn('blocked_by = ["010-a", "020-a"]', text)

    def test_cursor_join_fans_in_handles_and_dedupes(self):
        def build(s):
            a = s.thread("a", command="codex")
            b = s.thread("b", command="claude")
            x = a(body="x")
            y = a(body="y")
            b(s.cursor(x).join(y, x), body="join")

        text = render(build)
        self.assertIn('blocked_by = ["010-a", "020-a"]', text)

    def test_cursor_loop_parallel_reviewers_and_serial_iterations(self):
        def build(s):
            impl = s.thread("impl", command="codex")
            quality = s.thread("quality", command="claude")
            security = s.thread("security", command="claude")
            cursor = s.cursor()
            for plan_path in ("p1.md", "p2.md"):
                result = impl(cursor, prompts.implementer, plan_path, new=cursor.empty)
                q = quality(result, prompts.code_quality)
                sec = security(result, prompts.security)
                fix = impl(result, q, sec, prompts.implementer, compact=True)
                cursor = cursor.advance(fix)

        text = render(build)
        self.assertIn('name = "020-quality"', text)
        self.assertIn('blocked_by = ["010-impl"]', text)
        self.assertIn('name = "030-security"', text)
        self.assertIn('blocked_by = ["010-impl"]', text)
        self.assertIn('name = "050-impl"', text)
        self.assertIn('blocked_by = ["040-impl"]', text)

    def test_public_cursor_type(self):
        self.assertTrue(Cursor().empty)


class Names(unittest.TestCase):
    def test_labels_and_sanitization(self):
        def build(s):
            a = s.thread("a", command="codex")
            a(body="x", label="Parse Auth!")

        text = render(build)
        self.assertIn('name = "010-a-parse-auth"', text)

    def test_duplicate_name_rejected(self):
        with self.assertRaises(StakoError):
            with Stack("t", out=tempfile.mkdtemp(), dry_run=True) as s:
                a = s.thread("a", command="codex")
                a(body="x", name="dup")
                a(body="y", name="dup")


class Library(unittest.TestCase):
    def test_nicknames_resolve_to_files(self):
        for nick in stako.prompts.names():
            ref = prompts[nick]
            self.assertTrue(os.path.isfile(ref.path), ref.path)
        self.assertIn("implementer", stako.prompts.names())

    def test_unknown_nickname_errors(self):
        with self.assertRaises(StakoError):
            _ = prompts.does_not_exist

    def test_missing_prompt_file_errors(self):
        with self.assertRaises(StakoError):
            prompt("/no/such/file.md")

    def test_nickname_used_as_use_emits_path(self):
        def build(s):
            a = s.thread("a", command="codex")
            a(prompts.implementer)

        text = render(build)
        self.assertIn("use =", text)
        self.assertIn("implementer.md", text)

    def test_nested_prompt_names_resolve(self):
        self.assertIn("bug_finder/entrypoint_researcher", stako.prompts.names())
        ref = prompts["bug_finder/entrypoint_researcher"]
        self.assertTrue(ref.path.endswith("prompts/bug_finder/entrypoint_researcher.md"))


class Materialize(unittest.TestCase):
    def test_dry_run_writes_files_without_running(self):
        out = tempfile.mkdtemp(prefix="stako-test-")
        with Stack("t", out=out, dry_run=True) as s:
            a = s.thread("a", command="codex")
            a(body="x")
        self.assertTrue(os.path.isfile(os.path.join(out, "plan.toml")))

    def test_exception_in_block_queues_nothing(self):
        out = tempfile.mkdtemp(prefix="stako-test-")
        try:
            with Stack("t", out=out, dry_run=True) as s:
                s.thread("a", command="codex")
                raise ValueError("boom")
        except ValueError:
            pass
        self.assertFalse(os.path.isfile(os.path.join(out, "plan.toml")))


if __name__ == "__main__":
    unittest.main()
