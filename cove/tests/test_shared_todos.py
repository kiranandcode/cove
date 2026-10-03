#!/usr/bin/env python3

from __future__ import annotations

import importlib
import sys
import unittest
from pathlib import Path
from unittest import mock


MCP_DIR = Path(__file__).resolve().parents[1] / "mcp"
sys.path.insert(0, str(MCP_DIR))
cove_mcp = importlib.import_module("cove_mcp")


class SharedTodoTest(unittest.TestCase):
    def setUp(self) -> None:
        self.todo = {
            "id": "owner.todo", "type": "todo", "owner": "owner",
            "text": "Shared work", "items": [],
        }
        self.terms = [
            {"id": 10, "pane_id": 100, "session": "owner", "name": "Lead"},
            {"id": 11, "pane_id": 101, "session": "editor-a", "name": "Reviewer"},
            {"id": 12, "pane_id": 102, "session": "editor-b", "name": "Builder"},
        ]

    def call(self, name, args, session="owner", shape=None, terms=None):
        commands = []

        def capture(_path, command):
            commands.append(command)
            return {"ok": True, "confirmed": True}

        board = {"shapes": [shape or self.todo]}
        state = {"terminals": terms or self.terms}
        with mock.patch.object(cove_mcp, "read_board", return_value=board), \
                mock.patch.object(cove_mcp, "read_state", return_value=state), \
                mock.patch.object(cove_mcp, "my_session", return_value=session), \
                mock.patch.object(cove_mcp, "send", side_effect=capture):
            result = cove_mcp.call_tool(name, args)
        return result, commands

    def test_owner_shares_with_stable_sessions(self) -> None:
        result, commands = self.call(
            "share_todo", {"id": "owner.todo", "editors": ["Reviewer", "editor-b", "Reviewer"]})
        self.assertEqual(result["editors"], ["editor-a", "editor-b"])
        self.assertEqual(commands, [{
            "cmd": "board", "op": "update", "id": "owner.todo",
            "editors": ["editor-a", "editor-b"],
        }])

    def test_empty_editor_list_revokes_access(self) -> None:
        shared = dict(self.todo, editors=["editor-a"])
        result, commands = self.call(
            "share_todo", {"id": "owner.todo", "editors": []}, shape=shared)
        self.assertEqual(result["editors"], [])
        self.assertEqual(commands[0]["editors"], [])

    def test_editor_references_are_strictly_validated(self) -> None:
        for editors in ["editor-a", None, [""], [{}], [11]]:
            with self.subTest(editors=editors), \
                    self.assertRaisesRegex(ValueError, "list of nonempty"):
                self.call("share_todo", {"id": "owner.todo", "editors": editors})

    def test_only_owner_can_share_a_todo(self) -> None:
        with self.assertRaisesRegex(ValueError, "isn't yours"):
            self.call("share_todo", {"id": "owner.todo", "editors": ["editor-b"]},
                      session="editor-a")

    def test_only_todos_can_be_shared(self) -> None:
        note = dict(self.todo, type="note")
        with self.assertRaisesRegex(ValueError, "only todo"):
            self.call("share_todo", {"id": "owner.todo", "editors": ["editor-a"]},
                      shape=note)

    def test_ambiguous_or_unknown_termling_is_rejected(self) -> None:
        duplicate = self.terms + [
            {"id": 13, "pane_id": 103, "session": "editor-c", "name": "Reviewer"},
        ]
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.call("share_todo", {"id": "owner.todo", "editors": ["Reviewer"]},
                      terms=duplicate)
        numeric_collision = self.terms + [
            {"id": 13, "pane_id": 11, "session": "editor-c", "name": "Other"},
        ]
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.call("share_todo", {"id": "owner.todo", "editors": ["11"]},
                      terms=numeric_collision)
        with self.assertRaisesRegex(ValueError, "no termling"):
            self.call("share_todo", {"id": "owner.todo", "editors": ["gone"]})
        sessionless = self.terms + [
            {"id": 14, "pane_id": 104, "session": "", "name": "Learning"},
        ]
        with self.assertRaisesRegex(ValueError, "no stable session"):
            self.call("share_todo", {"id": "owner.todo", "editors": ["Learning"]},
                      terms=sessionless)

    def test_exact_session_beats_renamed_or_duplicate_labels(self) -> None:
        duplicate = self.terms + [
            {"id": 13, "pane_id": 103, "session": "editor-c", "name": "Reviewer"},
        ]
        result, _commands = self.call(
            "share_todo", {"id": "owner.todo", "editors": ["editor-a"]},
            terms=duplicate)
        self.assertEqual(result["editors"], ["editor-a"])

    def test_shared_editor_can_change_todo_content(self) -> None:
        shared = dict(self.todo, editors=["editor-a"])
        _result, commands = self.call("update_note", {
            "id": "owner.todo", "add_items": ["Review"],
            "check": "Review", "remove": "Old",
        }, session="editor-a", shape=shared)
        self.assertEqual(commands[0], {
            "cmd": "board", "op": "update", "id": "owner.todo",
            "add_items": ["Review"], "check": "Review", "remove": "Old",
        })

    def test_shared_editor_cannot_change_layout_or_style(self) -> None:
        shared = dict(self.todo, editors=["editor-a"])
        for field, value in [
                ("text", "Renamed"), ("items", ["replacement"]),
                ("color", "red"), ("x", 10), ("w", 500)]:
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "shared editors"):
                self.call("update_note", {"id": "owner.todo", field: value},
                          session="editor-a", shape=shared)
        with self.assertRaisesRegex(ValueError, "shared editors"):
            self.call("update_note", {
                "id": "owner.todo", "add_items": ["allowed"], "color": "red",
            }, session="editor-a", shape=shared)

    def test_malformed_or_non_todo_acl_grants_nothing(self) -> None:
        for shape in [
                dict(self.todo, editors="editor-a"),
                dict(self.todo, type="note", editors=["editor-a"])]:
            with self.assertRaisesRegex(ValueError, "isn't yours"):
                self.call("update_note", {"id": "owner.todo", "check": 0},
                          session="editor-a", shape=shape)

    def test_unlisted_editor_cannot_update_or_delete(self) -> None:
        shared = dict(self.todo, editors=["editor-a"])
        with self.assertRaisesRegex(ValueError, "isn't yours"):
            self.call("update_note", {"id": "owner.todo", "check": 0},
                      session="editor-b", shape=shared)
        with self.assertRaisesRegex(ValueError, "isn't yours"):
            self.call("delete_notes", {"ids": ["owner.todo"]},
                      session="editor-a", shape=shared)

    def test_owner_keeps_full_update_permissions(self) -> None:
        _result, commands = self.call(
            "update_note", {"id": "owner.todo", "color": "blue", "x": 20})
        self.assertEqual(commands[0]["color"], "blue")
        self.assertEqual(commands[0]["x"], 20)


if __name__ == "__main__":
    unittest.main()
