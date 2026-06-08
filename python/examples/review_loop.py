"""Implement -> review -> check loop, one iteration per file in plans/.

Run it from a directory that has a plans/*.md set:

    python3 review_loop.py        # writes plan.toml and runs `stako new`
    STAKO_BIN=true python3 review_loop.py   # smoke test without a real binary

Each thread carries a harness command; each prompt body comes from the bundled
library by nickname. Cursor data flow becomes blocked_by, so iterations can be
serialized without over-serializing reviewers inside one iteration.
"""

from stako import Stack, prompts

with Stack("review-loop", cwd="~/src/myrepo") as s:
    impl = s.thread("impl", command="codex")
    quality = s.thread("quality", command="claude")
    security = s.thread("security", command="claude")
    checker = s.thread("checker", command="claude")
    cursor = s.cursor()

    for task in s.glob("plans/*.md"):
        i = impl(cursor, prompts.implementer, task, new=cursor.empty)
        q = quality(prompts.code_quality, i)
        sec = security(prompts.security, i)
        c = checker(prompts.checker, q, sec)
        cursor = cursor.advance(c)
