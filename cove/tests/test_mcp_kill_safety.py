#!/usr/bin/env python3

from __future__ import annotations

import importlib
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


MCP_DIR = Path(__file__).resolve().parents[1] / "mcp"
sys.path.insert(0, str(MCP_DIR))
cove_mcp = importlib.import_module("cove_mcp")


class KillSessionTest(unittest.TestCase):
    def test_process_snapshot_records_birth_identity(self) -> None:
        snapshot = cove_mcp._process_snapshot()
        self.assertIsNotNone(snapshot)
        procs, _kids = snapshot
        self.assertIn(os.getpid(), procs)
        self.assertTrue(procs[os.getpid()]["start"])

    def test_failed_process_scan_is_unknown(self) -> None:
        failed = subprocess.CompletedProcess([], 1, "", "ps failed")
        with mock.patch.object(cove_mcp.subprocess, "run", return_value=failed):
            self.assertIsNone(cove_mcp._pids_of_session("cove-123"))

    def test_verified_absence_is_idempotent_success(self) -> None:
        with mock.patch.object(cove_mcp, "_session_refs", return_value=(None, [])):
            self.assertTrue(cove_mcp._kill_session("cove-123"))

    def test_sigkill_attempt_is_not_reported_as_success(self) -> None:
        tree = ((100, "master-start"), [(101, "child-start")])
        with mock.patch.object(cove_mcp, "_session_refs", return_value=tree), \
                mock.patch.object(cove_mcp, "_signal_refs",
                                  side_effect=lambda refs, _sig, *_rest: (list(refs), True)) as signaled, \
                mock.patch.object(cove_mcp, "_wait_refs_gone", return_value=False):
            self.assertFalse(cove_mcp._kill_session("cove-123"))
        self.assertEqual([call.args[1] for call in signaled.call_args_list],
                         [signal.SIGSTOP, signal.SIGKILL, signal.SIGCONT])
        self.assertEqual(list(signaled.call_args_list[1].args[0]),
                         [(101, "child-start")])

    def test_stale_process_identity_is_never_signaled(self) -> None:
        snapshot = ({100: {"start": "new"}}, {})
        with mock.patch.object(cove_mcp, "_process_snapshot", return_value=snapshot), \
                mock.patch.object(cove_mcp.os, "kill") as killed:
            self.assertEqual(cove_mcp._signal_refs([(100, "old")], signal.SIGKILL), ([], True))
        killed.assert_not_called()

    def test_partial_stop_failure_resumes_already_stopped_processes(self) -> None:
        tree = ((100, "master-start"), [(101, "child-start")])
        calls = []

        def signal_refs(refs, sig):
            refs = list(refs)
            calls.append((refs, sig))
            if sig == signal.SIGSTOP:
                return refs[:1], False
            return refs, True

        with mock.patch.object(cove_mcp, "_session_refs", return_value=tree), \
                mock.patch.object(cove_mcp, "_signal_refs", side_effect=signal_refs):
            self.assertFalse(cove_mcp._kill_session("cove-123"))
        self.assertEqual(calls[-1], ([(100, "master-start")], signal.SIGCONT))

    def test_signal_errors_do_not_skip_later_processes(self) -> None:
        snapshot = ({
            100: {"start": "one"},
            101: {"start": "two"},
        }, {})
        with mock.patch.object(cove_mcp, "_process_snapshot", return_value=snapshot), \
                mock.patch.object(cove_mcp.os, "kill",
                                  side_effect=[PermissionError(), None]) as killed:
            signaled, ok = cove_mcp._signal_refs(
                [(100, "one"), (101, "two")], signal.SIGCONT)
        self.assertFalse(ok)
        self.assertEqual(signaled, [(101, "two")])
        self.assertEqual(killed.call_count, 2)

    def test_failed_leaf_kill_keeps_master_for_retry(self) -> None:
        master = (100, "master")
        agent, shell = (102, "agent"), (101, "shell")
        state = {master, agent, shell}
        destructive = []
        attempts = 0

        def session_refs(_sess):
            if master not in state:
                return None, []
            return master, [ref for ref in (agent, shell) if ref in state]

        def signal_refs(refs, sig, best_effort=True):
            nonlocal attempts
            refs = list(refs)
            if sig == signal.SIGKILL:
                destructive.append(refs)
                if agent in refs and attempts == 0:
                    attempts += 1
                    return [], False
                for ref in refs:
                    state.discard(ref)
            return refs, True

        def refs_gone(refs, _timeout):
            return not any(ref in state for ref in refs)

        with mock.patch.object(cove_mcp, "_session_refs", side_effect=session_refs), \
                mock.patch.object(cove_mcp, "_signal_refs", side_effect=signal_refs), \
                mock.patch.object(cove_mcp, "_wait_refs_gone", side_effect=refs_gone):
            self.assertFalse(cove_mcp._kill_session("cove-123"))
            self.assertIn(master, state)
            self.assertTrue(cove_mcp._kill_session("cove-123"))
        self.assertEqual(destructive[0], [agent])
        self.assertEqual(state, set())

    def test_newly_discovered_leaf_stays_before_parent(self) -> None:
        master, shell, new_leaf = (100, "master"), (101, "shell"), (102, "leaf")
        scans = [
            (master, [shell]),
            (master, [new_leaf, shell]),
            (master, [new_leaf, shell]),
        ]
        destructive = []

        def session_refs(_sess):
            return scans.pop(0) if scans else (master, [new_leaf, shell])

        def signal_refs(refs, sig, best_effort=True):
            refs = list(refs)
            if sig == signal.SIGKILL:
                destructive.append(refs)
            return refs, True

        def refs_gone(refs, _timeout):
            return list(refs) == [new_leaf]

        with mock.patch.object(cove_mcp, "_session_refs", side_effect=session_refs), \
                mock.patch.object(cove_mcp, "_signal_refs", side_effect=signal_refs), \
                mock.patch.object(cove_mcp, "_wait_refs_gone", side_effect=refs_gone):
            self.assertFalse(cove_mcp._kill_session("cove-123"))
        self.assertEqual(destructive, [[new_leaf], [shell]])

    def test_session_lookup_requires_exact_abduco_argv(self) -> None:
        procs = {
            100: {"ppid": 1, "start": "master", "comm": "abduco",
                  "cmd": "/path/Cove App/bin/abduco -A cove-123 zsh"},
            101: {"ppid": 100, "start": "shell", "comm": "zsh", "cmd": "zsh"},
            102: {"ppid": 101, "start": "agent", "comm": "codex", "cmd": "codex"},
            200: {"ppid": 1, "start": "other", "comm": "agent",
                  "cmd": "agent prompt mentions abduco -A cove-123"},
            201: {"ppid": 200, "start": "other-child", "comm": "sleep", "cmd": "sleep"},
        }
        kids = {1: [100, 200], 100: [101], 101: [102], 200: [201]}
        with mock.patch.object(cove_mcp, "_process_snapshot", return_value=(procs, kids)):
            self.assertEqual(cove_mcp._session_refs("cove-123"),
                             ((100, "master"), [(102, "agent"), (101, "shell")]))

    def test_zombie_child_does_not_block_parent_teardown(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "child.pid"
            code = (
                "import pathlib,subprocess,sys; "
                "p=subprocess.Popen(['sleep','60']); "
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid)); p.wait()"
            )
            parent = subprocess.Popen(
                [sys.executable, "-c", code, str(marker)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            child_pid = None
            try:
                deadline = time.time() + 2
                while not marker.exists() and time.time() < deadline:
                    time.sleep(0.02)
                self.assertTrue(marker.exists(), "child pid was not published")
                child_pid = int(marker.read_text())
                snapshot = cove_mcp._process_snapshot()
                self.assertIsNotNone(snapshot)
                procs, _kids = snapshot
                master = (parent.pid, procs[parent.pid]["start"])
                child = (child_pid, procs[child_pid]["start"])
                with mock.patch.object(cove_mcp, "_session_refs",
                                       return_value=(master, [child])):
                    self.assertTrue(cove_mcp._kill_session("cove-test"))
                parent.wait(timeout=2)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait()
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_remote_failure_does_not_kill_local_control_session(self) -> None:
        failed = subprocess.CompletedProcess([], 1, "", "host unreachable")
        with mock.patch.object(cove_mcp.subprocess, "run", return_value=failed), \
                mock.patch.object(cove_mcp, "_kill_session") as local:
            ok, why = cove_mcp._terminate_child_session(
                "cove-123", {"host": "example"})
        self.assertFalse(ok)
        self.assertIn("host unreachable", why)
        local.assert_not_called()

    def test_remote_timeout_does_not_kill_local_control_session(self) -> None:
        with mock.patch.object(
                cove_mcp.subprocess, "run",
                side_effect=subprocess.TimeoutExpired(["cove-remote"], 15)), \
                mock.patch.object(cove_mcp, "_kill_session") as local:
            ok, why = cove_mcp._terminate_child_session(
                "cove-123", {"host": "example"})
        self.assertFalse(ok)
        self.assertIn("remote termination failed", why)
        local.assert_not_called()

    def test_remote_success_still_requires_local_control_session_exit(self) -> None:
        succeeded = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(cove_mcp.subprocess, "run", return_value=succeeded), \
                mock.patch.object(cove_mcp, "_kill_session", return_value=False):
            ok, why = cove_mcp._terminate_child_session(
                "cove-123", {"host": "example"})
        self.assertFalse(ok)
        self.assertIn("local session did not exit", why)


class KillTreeTest(unittest.TestCase):
    def _call(self, lineage, terminate, board=None, send_error=None):
        writes, commands = [], []

        def capture_write(value):
            writes.append(value)

        def capture_send(_path, value):
            if send_error:
                raise ValueError(send_error)
            commands.append(value)
            return {"ok": True, "confirmed": True}

        with mock.patch.object(cove_mcp, "_killable_child_session", return_value="root"), \
                mock.patch.object(cove_mcp, "read_lineage", return_value=lineage), \
                mock.patch.object(cove_mcp, "write_lineage", side_effect=capture_write), \
                mock.patch.object(cove_mcp, "_terminate_child_session", side_effect=terminate), \
                mock.patch.object(cove_mcp, "read_board_checked", return_value=board or {"shapes": []}), \
                mock.patch.object(cove_mcp, "send", side_effect=capture_send), \
                mock.patch.object(cove_mcp, "my_session", return_value="parent"):
            result = cove_mcp.call_tool("kill", {"id": "root"})
        return result, writes, commands

    def test_failure_keeps_lineage_visible_and_board_untouched(self) -> None:
        lineage = {"root": {"parent": "parent"}}
        result, writes, commands = self._call(lineage, lambda _s, _r: (False, "still alive"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["failed"], {"root": "still alive"})
        self.assertEqual(writes, [])
        self.assertEqual(commands, [])

    def test_cleanup_failure_keeps_closed_lineage_retryable(self) -> None:
        lineage = {"root": {"parent": "parent", "arrow": "parent.spawn"}}
        board = {"shapes": [
            {"id": "parent.spawn", "type": "arrow", "owner": "parent"},
        ]}
        result, writes, _commands = self._call(
            lineage, lambda _s, _r: (True, ""), board, "board unavailable")
        self.assertFalse(result["ok"])
        self.assertEqual(result["killed"], ["root"])
        self.assertEqual(result["cleanup_error"], "board unavailable")
        self.assertNotIn("dead", lineage["root"])
        self.assertEqual(writes, [])

        with mock.patch.object(cove_mcp, "_term", return_value=None), \
                mock.patch.object(cove_mcp, "my_session", return_value="parent"):
            self.assertEqual(cove_mcp._killable_child_session("root", lineage), "root")

    def test_missing_board_state_keeps_cleanup_retryable(self) -> None:
        lineage = {"root": {"parent": "parent", "arrow": "parent.spawn"}}
        with mock.patch.object(cove_mcp, "_killable_child_session", return_value="root"), \
                mock.patch.object(cove_mcp, "read_lineage", return_value=lineage), \
                mock.patch.object(cove_mcp, "write_lineage") as write_lineage, \
                mock.patch.object(cove_mcp, "_terminate_child_session", return_value=(True, "")), \
                mock.patch.object(cove_mcp, "read_board_checked",
                                  side_effect=ValueError("board state unavailable")), \
                mock.patch.object(cove_mcp, "send") as send, \
                mock.patch.object(cove_mcp, "my_session", return_value="parent"):
            result = cove_mcp.call_tool("kill", {"id": "root"})
        self.assertFalse(result["ok"])
        self.assertIn("board state unavailable", result["cleanup_error"])
        self.assertNotIn("dead", lineage["root"])
        write_lineage.assert_not_called()
        send.assert_not_called()

    def test_failed_grandchild_retains_ancestors_but_not_siblings(self) -> None:
        lineage = {
            "root": {"parent": "parent"},
            "failed-leaf": {"parent": "root"},
            "sibling": {"parent": "root"},
        }
        attempted = []

        def terminate(sess, _rec):
            attempted.append(sess)
            return (False, "still alive") if sess == "failed-leaf" else (True, "")

        result, writes, _commands = self._call(lineage, terminate)
        self.assertEqual(result["killed"], ["sibling"])
        self.assertEqual(result["failed"], {"failed-leaf": "still alive"})
        self.assertIn("root", result["retained"])
        self.assertNotIn("root", attempted)
        self.assertNotIn("dead", lineage["root"])
        self.assertNotIn("dead", lineage["failed-leaf"])
        self.assertIn("dead", lineage["sibling"])
        self.assertEqual(len(writes), 1)

    def test_only_authorized_arrows_are_removed(self) -> None:
        lineage = {"child": {"arrow": "parent.spawn", "frame": "parent.frame"}}
        board = {"shapes": [
            {"id": "parent.spawn", "type": "arrow", "owner": "parent"},
            {"id": "parent.frame", "type": "frame", "owner": "parent"},
            {"id": "child.bound", "type": "arrow", "owner": "child",
             "bind_a": "term:child"},
            {"id": "user.bound", "type": "arrow", "owner": "",
             "bind_a": "term:child"},
            {"id": "other.bound", "type": "arrow", "owner": "other",
             "bind_b": "term:child"},
        ]}
        ids = cove_mcp._killed_shape_ids(
            ["child"], ["parent", "child"], lineage, board)
        self.assertEqual(ids, ["child.bound", "parent.frame", "parent.spawn"])


if __name__ == "__main__":
    unittest.main()
