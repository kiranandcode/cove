#!/usr/bin/env python3
import contextlib
import io
import signal
import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "mcp"))
import cove_mcp  # noqa: E402


class SessionCleanupTest(unittest.TestCase):
    def test_finds_only_the_exact_abduco_session_tree(self) -> None:
        processes = """\
5 1 /opt/homebrew/bin/abduco -A cove-999 /usr/bin/printf -A cove-123
6 5 sleep 60
10 1 /opt/homebrew/bin/abduco -A cove-123 /bin/zsh
11 10 /bin/zsh
12 11 codex
20 1 /opt/homebrew/bin/abduco -A cove-1234 /bin/zsh
21 20 /bin/zsh
30 1 /bin/sh -c abduco -A cove-123 /bin/zsh
31 30 sleep 60
40 1 /opt/homebrew/bin/abduco -a cove-123
"""
        self.assertEqual(cove_mcp._session_processes(processes, "cove-123"), (10, [11, 12]))
        self.assertEqual(cove_mcp._session_processes(processes, "cove-12"), (None, []))

    def test_stubborn_session_gets_killed_master_last(self) -> None:
        trees = [(10, [11, 12]), (10, [12, 13]), (10, [13]), (None, [])]
        with mock.patch.object(cove_mcp, "_pids_of_session", side_effect=trees), \
                mock.patch.object(cove_mcp.os, "kill") as kill, \
                mock.patch.object(cove_mcp.time, "sleep"):
            self.assertTrue(cove_mcp._kill_session("cove-123"))

        self.assertEqual(kill.call_args_list, [
            mock.call(11, signal.SIGHUP), mock.call(12, signal.SIGHUP),
            mock.call(12, signal.SIGTERM), mock.call(13, signal.SIGTERM),
            mock.call(13, signal.SIGKILL), mock.call(10, signal.SIGKILL),
        ])

    def test_kill_failure_is_reported(self) -> None:
        with mock.patch.object(cove_mcp, "_pids_of_session", return_value=(10, [11])), \
                mock.patch.object(cove_mcp.os, "kill", side_effect=PermissionError), \
                mock.patch.object(cove_mcp.time, "sleep"):
            self.assertFalse(cove_mcp._kill_session("cove-123"))

    def test_cli_rejects_non_session_names(self) -> None:
        with mock.patch.object(cove_mcp, "_kill_session") as kill, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cove_mcp._kill_session_cli(["--kill-session", "cove-123;kill 1"]), 2)
            kill.assert_not_called()

        with mock.patch.object(cove_mcp, "_kill_session", return_value=True) as kill:
            self.assertEqual(cove_mcp._kill_session_cli(["--kill-session", "cove-123"]), 0)
            kill.assert_called_once_with("cove-123")


if __name__ == "__main__":
    unittest.main()
