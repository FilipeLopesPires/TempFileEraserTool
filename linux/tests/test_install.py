"""install.sh and uninstall.sh, run against a throwaway HOME.

Marked integration because they shell out and write files, but they are safe: HOME,
XDG_DATA_HOME and XDG_CONFIG_HOME all point into tmp_path, and PATH is led by stub
nautilus and pgrep commands so the developer's own file manager is never restarted.

    pytest -m 'not integration'    to skip them
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.integration

LINUX_DIR = Path(__file__).resolve().parent.parent


@pytest.fixture
def sandbox(tmp_path):
    home = tmp_path / 'home'
    stubs = tmp_path / 'stubs'
    home.mkdir()
    stubs.mkdir()
    # Found on PATH so the Nautilus branch runs, but they do nothing. pgrep always
    # reports "not running", so the real Nautilus is never asked to quit. dpkg-query
    # reports the package edition as absent, so the result does not depend on what
    # happens to be installed on the machine running the tests.
    (stubs / 'nautilus').write_text('#!/bin/sh\nexit 0\n')
    (stubs / 'pgrep').write_text('#!/bin/sh\nexit 1\n')
    (stubs / 'dpkg-query').write_text('#!/bin/sh\nexit 1\n')
    for stub in ('nautilus', 'pgrep', 'dpkg-query'):
        (stubs / stub).chmod(0o755)

    environment = dict(os.environ)
    environment.update({
        'HOME': str(home),
        'XDG_DATA_HOME': str(home / '.local' / 'share'),
        'XDG_CONFIG_HOME': str(home / '.config'),
        'PATH': f'{stubs}:{environment["PATH"]}',
    })
    return home, environment


def run(script: str, environment: dict, expect_success: bool = True):
    completed = subprocess.run(['bash', str(LINUX_DIR / script)], env=environment,
                               capture_output=True, text=True, timeout=120)
    if expect_success:
        assert completed.returncode == 0, completed.stderr
    return completed


def installed_paths(home: Path) -> dict[str, Path]:
    data = home / '.local' / 'share'
    return {
        'launcher': home / '.local' / 'bin' / 'temp-file-eraser',
        'package': data / 'temp-file-eraser' / 'tempfileeraser' / '__main__.py',
        'rules': data / 'temp-file-eraser' / 'tempfileeraser' / 'rules.json',
        'version': data / 'temp-file-eraser' / 'tempfileeraser' / 'VERSION',
        'desktop': data / 'applications' / 'temp-file-eraser.desktop',
    }


def nautilus_paths(home: Path) -> tuple[Path, Path]:
    """The top-level extension, and the Scripts-submenu fallback."""
    data = home / '.local' / 'share'
    return (data / 'nautilus-python' / 'extensions' / 'temp-file-eraser-nautilus.py',
            data / 'nautilus' / 'scripts' / 'Clean up temp and cache folders')


def has_nautilus_python() -> bool:
    """The same question install.sh asks, so the test follows the same branch."""
    probe = (
        "import gi\n"
        "for api in ('4.0', '3.0'):\n"
        "    try:\n"
        "        gi.require_version('Nautilus', api)\n"
        "        from gi.repository import Nautilus\n"
        "        raise SystemExit(0)\n"
        "    except (ValueError, ImportError):\n"
        "        continue\n"
        "raise SystemExit(1)\n")
    return subprocess.run([sys.executable, '-c', probe],
                          capture_output=True, timeout=60).returncode == 0


class TestInstall:
    def test_installs_every_piece(self, sandbox):
        home, environment = sandbox
        run('install.sh', environment)
        for name, path in installed_paths(home).items():
            assert path.exists(), f'{name} was not installed'

    def test_installs_exactly_one_nautilus_entry(self, sandbox):
        home, environment = sandbox
        run('install.sh', environment)
        extension, fallback = nautilus_paths(home)
        if has_nautilus_python():
            assert extension.exists(), 'the top-level extension was not installed'
            assert not fallback.exists(), 'the Scripts fallback would be a second entry'
        else:
            assert fallback.exists(), 'the Scripts fallback was not installed'
            assert not extension.exists()

    def test_the_launcher_runs_the_installed_copy(self, sandbox):
        home, environment = sandbox
        run('install.sh', environment)
        launcher = installed_paths(home)['launcher']
        completed = subprocess.run([str(launcher), '--version'], env=environment,
                                   capture_output=True, text=True, timeout=60)
        assert completed.returncode == 0, completed.stderr
        assert 'Temp File Eraser' in completed.stdout

    def test_the_installed_copy_finds_its_own_rules(self, sandbox, tmp_path):
        home, environment = sandbox
        run('install.sh', environment)
        project = tmp_path / 'project'
        (project / 'node_modules').mkdir(parents=True)
        (project / 'node_modules' / 'index.js').write_text('x')
        completed = subprocess.run([str(installed_paths(home)['launcher']), str(project), '--list'],
                                   env=environment, capture_output=True, text=True, timeout=60)
        assert 'Node.js dependencies' in completed.stdout

    def test_the_desktop_entry_points_at_an_absolute_command(self, sandbox):
        home, environment = sandbox
        run('install.sh', environment)
        text = installed_paths(home)['desktop'].read_text()
        exec_line = next(line for line in text.splitlines() if line.startswith('Exec='))
        assert exec_line == f'Exec={home}/.local/bin/temp-file-eraser %f'

    def test_running_it_twice_is_safe(self, sandbox):
        home, environment = sandbox
        run('install.sh', environment)
        run('install.sh', environment)
        assert installed_paths(home)['package'].exists()

    def test_refuses_when_the_package_edition_is_installed(self, sandbox, tmp_path):
        home, environment = sandbox
        stubs = Path(environment['PATH'].split(':')[0])
        (stubs / 'dpkg-query').write_text(
            '#!/bin/sh\nprintf "install ok installed"\nexit 0\n')
        (stubs / 'dpkg-query').chmod(0o755)
        completed = run('install.sh', environment, expect_success=False)
        assert completed.returncode != 0
        assert 'package edition' in completed.stderr
        assert not installed_paths(home)['package'].exists()


class TestUninstall:
    def test_removes_everything_it_installed(self, sandbox):
        home, environment = sandbox
        run('install.sh', environment)
        run('uninstall.sh', environment)
        for name, path in installed_paths(home).items():
            assert not path.exists(), f'{name} was left behind'
        for path in nautilus_paths(home):
            assert not path.exists(), f'{path.name} was left behind'

    def test_removes_the_extension_bytecode(self, sandbox):
        home, environment = sandbox
        run('install.sh', environment)
        extension, _fallback = nautilus_paths(home)
        cache = extension.parent / '__pycache__'
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.mkdir(exist_ok=True)
        (cache / 'temp-file-eraser-nautilus.cpython-310.pyc').write_bytes(b'stale')
        run('uninstall.sh', environment)
        assert not list(cache.glob('temp-file-eraser-nautilus.*.pyc'))

    def test_is_safe_to_run_without_an_install(self, sandbox):
        _home, environment = sandbox
        run('uninstall.sh', environment)


class TestThunarAction:
    def script(self):
        return LINUX_DIR / 'integrations' / 'thunar_action.py'

    def test_creates_the_file_when_absent(self, tmp_path):
        uca = tmp_path / 'Thunar' / 'uca.xml'
        subprocess.run([sys.executable, str(self.script()), '--install', str(uca), '/bin/tfe'],
                       check=True, timeout=30)
        assert 'temp-file-eraser-tool-1' in uca.read_text()

    def test_keeps_other_actions(self, tmp_path):
        uca = tmp_path / 'uca.xml'
        uca.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<actions>\n'
                       '<action><name>Mine</name><unique-id>other</unique-id>'
                       '<command>x</command></action>\n</actions>\n')
        subprocess.run([sys.executable, str(self.script()), '--install', str(uca), '/bin/tfe'],
                       check=True, timeout=30)
        text = uca.read_text()
        assert '<unique-id>other</unique-id>' in text
        assert '<unique-id>temp-file-eraser-tool-1</unique-id>' in text

    def test_installing_twice_does_not_duplicate(self, tmp_path):
        uca = tmp_path / 'uca.xml'
        for _ in range(2):
            subprocess.run([sys.executable, str(self.script()), '--install', str(uca), '/bin/tfe'],
                           check=True, timeout=30)
        assert uca.read_text().count('temp-file-eraser-tool-1') == 1

    def test_removal_leaves_other_actions_alone(self, tmp_path):
        uca = tmp_path / 'uca.xml'
        uca.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<actions>\n'
                       '<action><name>Mine</name><unique-id>other</unique-id>'
                       '<command>x</command></action>\n</actions>\n')
        subprocess.run([sys.executable, str(self.script()), '--install', str(uca), '/bin/tfe'],
                       check=True, timeout=30)
        subprocess.run([sys.executable, str(self.script()), '--remove', str(uca)],
                       check=True, timeout=30)
        text = uca.read_text()
        assert 'temp-file-eraser-tool-1' not in text
        assert '<unique-id>other</unique-id>' in text
