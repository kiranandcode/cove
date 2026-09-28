#!/usr/bin/env python3

from __future__ import annotations

import fcntl
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class RunRecoveryTest(unittest.TestCase):
    def write_executable(self, path: Path, body: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)

    def spawn(self, argv: list[str], env: dict[str, str]) -> None:
        proc = subprocess.Popen(argv, env=env)
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)

    def run_launcher(
        self, sessions: list[str], *, attached: list[str] = (),
        lock_held: bool = False, kitty_alive: bool = False,
        godot_alive: bool = False, stuck_kitty: bool = False,
        iosurface: str | None = None, probe_ok: bool = True,
        inherited_kitty_iosurface: bool = False,
        extension_registered: bool = True,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        temp = tempfile.TemporaryDirectory(prefix='cove-run-test-')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        repo = root / 'repo'
        runtime = root / 'runtime' / 'cove'
        socket = Path(f'{runtime}-kitty')
        fake_bin = root / 'bin'

        source = (REPO_ROOT / 'cove' / 'run.sh').read_text().replace('/tmp/cove', str(runtime))
        launcher = repo / 'cove' / 'run.sh'
        self.write_executable(launcher, source)
        self.write_executable(
            repo / 'cove' / 'cove-iosurface.sh',
            (REPO_ROOT / 'cove' / 'cove-iosurface.sh').read_text(),
        )
        probe = repo / 'cove' / 'scripts' / 'IOSurfaceProbe.gd'
        probe.parent.mkdir(parents=True, exist_ok=True)
        probe.write_text((REPO_ROOT / 'cove' / 'scripts' / 'IOSurfaceProbe.gd').read_text())
        extension_list = repo / 'cove' / '.godot' / 'extension_list.cfg'
        if extension_registered:
            extension_list.parent.mkdir(parents=True)
            extension_list.write_text('res://cove.gdextension\n')

        kitty = repo / 'kitty' / 'launcher' / 'kitty'
        self.write_executable(
            kitty,
            '#!/bin/sh\n'
            'printf "%s\\n" "$@" > "$KITTY_ARGS"\n'
            'printf "%s" "${KITTY_COVE_IOSURFACE-<unset>}" > "$KITTY_IOSURFACE"\n'
            'mkdir -p "$KITTY_COVE_DIR"\n'
            ': > "$KITTY_COVE_DIR/term-9.rgba"\n'
            ': > "$KITTY_READY"\n'
            'while [ ! -f "$GODOT_DONE" ]; do sleep 0.01; done\n',
        )
        self.write_executable(
            repo / 'kitty' / 'launcher' / 'kitty.app' / 'Contents' / 'MacOS' / 'kitten',
            '#!/bin/sh\n'
            'case "${4:-}" in\n'
            'ls) [ -f "$KITTY_READY" ] || exit 1; printf \'%s\\n\' \'[{"title":"ready"}]\' ;;\n'
            'launch) printf "%s\\n" "$*" >> "$LAUNCH_ARGS" ;;\n'
            'resize-os-window) printf "%s\\n" "$*" >> "$RESIZE_ARGS" ;;\n'
            'esac\n',
        )
        # Once kitty is up, its reattached clients show as attached ("*").
        self.write_executable(
            repo / 'cove' / 'bin' / 'abduco',
            '#!/bin/sh\n'
            'if [ -f "$KITTY_READY" ]; then sed "s/^  /* /" "$ABDUCO_LIST"; else cat "$ABDUCO_LIST"; fi\n',
        )
        self.write_executable(repo / 'cove' / 'cove-shell.sh', '#!/bin/sh\nexit 0\n')
        self.write_executable(repo / 'cove' / 'cove-remote-start.sh', '#!/bin/sh\nexit 0\n')
        godot = fake_bin / 'godot'
        self.write_executable(
            godot,
            '#!/bin/sh\n'
            'case " $* " in\n'
            '  *" --editor "*) mkdir -p "$(dirname "$EXTENSION_LIST")"; '
            'printf "%s\\n" res://cove.gdextension > "$EXTENSION_LIST"; : > "$IMPORT_CALLED"; exit 0 ;;\n'
            '  *" --script res://scripts/IOSurfaceProbe.gd "*) : > "$PROBE_CALLED"; '
            '[ "$PROBE_OK" = 1 ] && echo COVE_IOSURFACE_PROBE=1; exit 0 ;;\n'
            '  *" --script "*) exit 0 ;;\n'
            'esac\n'
            ': > "$GODOT_DONE"\n',
        )

        runtime.mkdir(parents=True)
        (runtime / 'state.json').write_text('saved-layout\n')
        (runtime / 'term-7.rgba').write_text('stale-kitty-frame\n')
        (runtime / 'term-1000000.rgba').write_text('app-frame\n')
        for stale in ('kitty.pid', 'dev-env', 'events.jsonl'):
            (runtime / stale).write_text('stale\n')
        socket.write_text('stale-socket\n')
        listing = ['Active sessions (on host test)']
        listing.extend(f'  Thu 2026-09-24 00:00:00 {session}' for session in sessions)
        listing.extend(f'* Thu 2026-09-24 00:00:00 {session}' for session in attached)
        listing.append('+ Thu 2026-09-24 00:00:00 cove-333')
        (root / 'abduco-list').write_text('\n'.join(listing) + '\n')

        env = {
            'ABDUCO_LIST': str(root / 'abduco-list'),
            'GODOT': str(godot),
            'GODOT_DONE': str(root / 'godot-done'),
            'EXTENSION_LIST': str(extension_list),
            'HOME': str(root / 'home'),
            'IMPORT_CALLED': str(root / 'import-called'),
            'KITTY_ARGS': str(root / 'kitty-args'),
            'KITTY_IOSURFACE': str(root / 'kitty-iosurface'),
            'KITTY_READY': str(root / 'kitty-ready'),
            'LAUNCH_ARGS': str(root / 'launch-args'),
            'PATH': f'{fake_bin}:/usr/bin:/bin',
            'PROBE_CALLED': str(root / 'probe-called'),
            'PROBE_OK': '1' if probe_ok else '0',
            'RESIZE_ARGS': str(root / 'resize-args'),
            'SHELL': '/bin/zsh',
        }
        if iosurface is not None:
            env['COVE_IOSURFACE'] = iosurface
        if inherited_kitty_iosurface:
            env['KITTY_COVE_IOSURFACE'] = '1'
        if kitty_alive:
            (root / 'kitty-ready').write_text('')
        if godot_alive:
            live_godot = root / 'live' / 'godot'
            self.write_executable(live_godot, '#!/bin/sh\nwhile :; do sleep 0.1; done\n')
            self.spawn(['/bin/sh', str(live_godot), '--path', str(repo / 'cove')], env)
        if stuck_kitty:
            # Alive but never serves remote control.
            self.spawn(['/bin/sh', str(kitty), '--title', 'cove'], {
                **env, 'KITTY_ARGS': str(root / 'stuck-args'),
                'KITTY_READY': str(root / 'stuck-ready'), 'KITTY_COVE_DIR': str(root / 'stuck'),
            })
        lock_file = None
        if lock_held:
            lock_file = Path(f'{runtime}-launch.lock').open('w')
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            result = subprocess.run(
                ['/bin/bash', str(launcher)], cwd=repo, env=env,
                text=True, capture_output=True, timeout=30, check=False,
            )
        finally:
            if lock_file is not None:
                fcntl.flock(lock_file, fcntl.LOCK_UN)
                lock_file.close()
        return result, root

    def test_concurrent_launcher_is_rejected(self) -> None:
        result, root = self.run_launcher([], lock_held=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another Cove launch is already in progress', result.stderr)
        self.assertFalse((root / 'kitty-args').exists())

    def test_cold_start_keeps_existing_behavior(self) -> None:
        result, root = self.run_launcher([])
        runtime = root / 'runtime' / 'cove'

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((runtime / 'state.json').exists())
        self.assertEqual((root / 'kitty-args').read_text().splitlines()[-1], str(root / 'repo/cove/cove-shell.sh'))
        self.assertFalse((root / 'launch-args').exists())
        self.assertFalse((root / 'resize-args').exists())

    def test_restart_recovers_sessions_and_repaints(self) -> None:
        result, root = self.run_launcher(['cove-111', 'cove-bad', 'cove-222'])
        runtime = root / 'runtime' / 'cove'

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((runtime / 'state.json').read_text(), 'saved-layout\n')
        self.assertFalse((runtime / 'term-7.rgba').exists())
        self.assertTrue((runtime / 'term-1000000.rgba').exists())
        for stale in ('kitty.pid', 'dev-env', 'events.jsonl'):
            self.assertFalse((runtime / stale).exists(), stale)
        self.assertEqual(
            (root / 'kitty-args').read_text().splitlines()[-3:],
            [str(root / 'repo/cove/bin/abduco'), '-a', 'cove-111'],
        )
        self.assertIn('-a cove-222', (root / 'launch-args').read_text())
        self.assertNotIn('cove-333', (root / 'launch-args').read_text())
        self.assertEqual(
            (root / 'resize-args').read_text().splitlines(),
            [
                f'@ --to unix:{root / "runtime/cove-kitty"} resize-os-window --match all --unit cells --incremental --width 1',
                f'@ --to unix:{root / "runtime/cove-kitty"} resize-os-window --match all --unit cells --incremental --width=-1',
            ],
        )

    def test_sessions_attached_elsewhere_are_skipped(self) -> None:
        result, root = self.run_launcher(['cove-111'], attached=['cove-444'])
        runtime = root / 'runtime' / 'cove'

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('skipping 1 session(s) attached elsewhere: cove-444', result.stderr)
        self.assertEqual(
            (root / 'kitty-args').read_text().splitlines()[-3:],
            [str(root / 'repo/cove/bin/abduco'), '-a', 'cove-111'],
        )
        self.assertFalse((root / 'launch-args').exists())
        self.assertEqual((runtime / 'state.json').read_text(), 'saved-layout\n')

    def test_only_attached_sessions_keeps_layout(self) -> None:
        result, root = self.run_launcher([], attached=['cove-444'])
        runtime = root / 'runtime' / 'cove'

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / 'kitty-args').read_text().splitlines()[-1], str(root / 'repo/cove/cove-shell.sh'))
        self.assertEqual((runtime / 'state.json').read_text(), 'saved-layout\n')
        self.assertFalse((runtime / 'kitty.pid').exists())

    def test_live_kitty_without_godot_relaunches_godot(self) -> None:
        result, root = self.run_launcher(['cove-111'], kitty_alive=True)
        runtime = root / 'runtime' / 'cove'

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('relaunching Godot', result.stdout)
        self.assertTrue((root / 'godot-done').exists())
        self.assertFalse((root / 'kitty-args').exists())
        self.assertEqual((runtime / 'kitty.pid').read_text(), 'stale\n')

    def test_live_kitty_reports_that_transport_changes_need_a_restart(self) -> None:
        result, root = self.run_launcher(['cove-111'], kitty_alive=True, iosurface='1')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('IOSurface mode is unchanged', result.stderr)
        self.assertIn('cove/reload-kitty.sh', result.stderr)
        self.assertFalse((root / 'probe-called').exists())

    def test_live_kitty_and_godot_is_rejected(self) -> None:
        result, root = self.run_launcher([], kitty_alive=True, godot_alive=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cove is already running', result.stderr)
        self.assertFalse((root / 'godot-done').exists())

    def test_unresponsive_kitty_is_rejected(self) -> None:
        result, root = self.run_launcher(['cove-111'], stuck_kitty=True)
        runtime = root / 'runtime' / 'cove'

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not answering', result.stderr)
        self.assertFalse((root / 'kitty-args').exists())
        self.assertEqual((runtime / 'kitty.pid').read_text(), 'stale\n')

    def test_iosurface_mode_requires_a_successful_class_probe(self) -> None:
        result, root = self.run_launcher([], iosurface='1')

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / 'kitty-iosurface').read_text(), '1')
        self.assertTrue((root / 'probe-called').exists())

    def test_iosurface_mode_imports_before_the_first_class_probe(self) -> None:
        result, root = self.run_launcher(
            [], iosurface='1', extension_registered=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / 'kitty-iosurface').read_text(), '1')
        self.assertTrue((root / 'import-called').exists())
        self.assertTrue((root / 'probe-called').exists())

    def test_iosurface_mode_falls_back_when_the_class_probe_fails(self) -> None:
        result, root = self.run_launcher([], iosurface='1', probe_ok=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / 'kitty-iosurface').read_text(), '<unset>')
        self.assertIn('CoveIOSurface is unavailable', result.stderr)

    def test_explicit_zero_clears_an_inherited_kitty_flag(self) -> None:
        result, root = self.run_launcher(
            [], iosurface='0', inherited_kitty_iosurface=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / 'kitty-iosurface').read_text(), '<unset>')
        self.assertFalse((root / 'probe-called').exists())

    def test_invalid_iosurface_mode_is_rejected_before_kitty_starts(self) -> None:
        result, root = self.run_launcher([], iosurface='yes')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('COVE_IOSURFACE must be 0 or 1', result.stderr)
        self.assertFalse((root / 'kitty-args').exists())
        runtime = root / 'runtime' / 'cove'
        self.assertEqual((runtime / 'state.json').read_text(), 'saved-layout\n')
        self.assertEqual((runtime / 'term-1000000.rgba').read_text(), 'app-frame\n')


if __name__ == '__main__':
    unittest.main()
