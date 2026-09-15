#!/usr/bin/python3 -B
# Tests for tools/penguid-pam-gate: python3 tests/pam-gate-test.py
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import stat
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("pam_gate", str(ROOT / "tools" / "penguid-pam-gate"))
gate = importlib.util.module_from_spec(importlib.util.spec_from_loader("pam_gate", loader))
loader.exec_module(gate)

HOUR = 3600 * 1000
NOW = 1789488000000
passed = 0


def test(fn):
    global passed
    try:
        fn()
    except Exception:
        print("FAIL " + fn.__name__)
        raise
    passed += 1
    return fn


@test
def the_rules_match_the_lock_screen():
    assert gate.block_reason(NOW, 5, NOW, NOW) == "failures"
    assert gate.block_reason(0, 0, 0, NOW) == "unknown"
    assert gate.block_reason(0, 0, NOW - 49 * HOUR, NOW) == "48h"
    assert gate.block_reason(NOW - 47 * HOUR, 0, NOW - 70 * HOUR, NOW) == ""
    assert gate.block_reason(NOW - 60 * HOUR, 4, NOW - HOUR, NOW) == ""


@test
def state_reads_like_the_lock_screen():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "state.json")
        assert gate.read_state(path) == (0, 0)
        pathlib.Path(path).write_text('{"version": 1, "lastPasswordAt": 1789000000000, "faceFailures": 3}\n')
        assert gate.read_state(path) == (1789000000000, 3)
        pathlib.Path(path).write_text("not json")
        assert gate.read_state(path) == (0, 0)
        pathlib.Path(path).write_text('{"lastPasswordAt": "soon", "faceFailures": -2}')
        assert gate.read_state(path) == (0, 0)
        pathlib.Path(path).write_text('{"lastPasswordAt": 7, "faceFailures": 1e300}')
        assert gate.read_state(path)[1] >= gate.FAILURE_LIMIT
        pathlib.Path(path).write_text(" " * (gate.STATE_CAP + 1) + "{}")
        assert gate.read_state(path) == (0, 0)


@test
def links_and_fifos_are_not_followed():
    with tempfile.TemporaryDirectory() as tmp:
        real = os.path.join(tmp, "real.json")
        pathlib.Path(real).write_text('{"lastPasswordAt": 5, "faceFailures": 0}')
        link = os.path.join(tmp, "state.json")
        os.symlink(real, link)
        assert gate.read_state(link) == (0, 0)
        fifo = os.path.join(tmp, "fifo.json")
        os.mkfifo(fifo)
        assert gate.read_state(fifo) == (0, 0)


@test
def record_writes_the_lock_screen_format():
    with tempfile.TemporaryDirectory() as tmp:
        path = gate.state_path(tmp)
        gate.write_state(path, NOW)
        text = pathlib.Path(path).read_text()
        assert text == '{\n  "version": 1,\n  "lastPasswordAt": %d,\n  "faceFailures": 0\n}\n' % NOW
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
        assert os.listdir(os.path.dirname(path)) == ["state.json"]
        assert gate.read_state(path) == (NOW, 0)


@test
def unknown_users_and_root_get_no_face():
    saved = os.environ.pop("PAM_USER", None)
    try:
        assert gate.check() == 1
        os.environ["PAM_USER"] = "no-such-user-penguid"
        assert gate.check() == 1
        assert gate.record() == 0
        os.environ["PAM_USER"] = "root"
        assert gate.check() == 1
        assert gate.record() == 0
    finally:
        os.environ.pop("PAM_USER", None)
        if saved is not None:
            os.environ["PAM_USER"] = saved


print("pam gate tests: %d passed" % passed)
