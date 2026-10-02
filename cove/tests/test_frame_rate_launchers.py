#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
REPAINT_OPTION = '-o repaint_delay=16'
GODOT_OPTION = '--max-fps 60'


class FrameRateLauncherTest(unittest.TestCase):
    def test_every_kitty_launcher_caps_cove_rendering(self) -> None:
        for name in ('run.sh', 'dev.sh', 'reload-kitty.sh'):
            with self.subTest(name=name):
                source = (REPO_ROOT / 'cove' / name).read_text()
                self.assertIn(REPAINT_OPTION, source)

    def test_every_godot_launcher_caps_cove_rendering(self) -> None:
        expected_launches = {
            'run.sh': 2,
            'dev.sh': 1,
            'reload.sh': 1,
            'reload-kitty.sh': 1,
        }
        for name, expected_count in expected_launches.items():
            with self.subTest(name=name):
                source = (REPO_ROOT / 'cove' / name).read_text()
                capped_lines = [line for line in source.splitlines() if GODOT_OPTION in line]
                self.assertEqual(len(capped_lines), expected_count)
                for line in capped_lines:
                    self.assertRegex(line, r'"\$GODOT" --path .+ --max-fps 60')


if __name__ == '__main__':
    unittest.main()
