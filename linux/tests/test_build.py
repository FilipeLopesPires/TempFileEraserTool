"""build.sh, mirroring tests/Build.Tests.ps1."""

import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.integration

LINUX_DIR = Path(__file__).resolve().parent.parent
REPO_DIR = LINUX_DIR.parent
VERSION = (REPO_DIR / 'VERSION').read_text(encoding='utf-8').splitlines()[0].strip()


def build(output: Path, *extra: str):
    completed = subprocess.run(['bash', str(LINUX_DIR / 'build.sh'), '--output', str(output),
                                *extra],
                               capture_output=True, text=True, timeout=300)
    return completed


@pytest.fixture(scope='module')
def tarball(tmp_path_factory):
    output = tmp_path_factory.mktemp('dist-script')
    completed = build(output, '--skip-deb')
    assert completed.returncode == 0, completed.stderr
    return output / 'TempFileEraserTool-Linux-Script.tar.gz'


class TestScriptEdition:
    def test_builds_the_tarball(self, tarball):
        assert tarball.exists()

    def test_contains_everything_install_sh_needs(self, tarball):
        with tarfile.open(tarball) as archive:
            names = {Path(name).relative_to('TempFileEraserTool-Linux').as_posix()
                     for name in archive.getnames()
                     if name != 'TempFileEraserTool-Linux'}
        for required in ('install.sh', 'uninstall.sh', 'rules.json', 'VERSION', 'LICENSE.md',
                         'tempfileeraser/__main__.py', 'tempfileeraser/rules.py',
                         'tempfileeraser/window.py',
                         'integrations/nautilus/temp-file-eraser-nautilus.py',
                         'integrations/temp-file-eraser.desktop',
                         'integrations/thunar_action.py'):
            assert required in names, f'{required} is missing from the tarball'

    def test_ships_every_module(self, tarball):
        with tarfile.open(tarball) as archive:
            packaged = {Path(name).name for name in archive.getnames()
                        if name.endswith('.py') and '/tempfileeraser/' in name}
        assert packaged == {path.name for path in (LINUX_DIR / 'tempfileeraser').glob('*.py')}

    def test_install_scripts_stay_executable(self, tarball):
        with tarfile.open(tarball) as archive:
            modes = {Path(member.name).name: member.mode for member in archive.getmembers()}
        assert modes['install.sh'] & 0o111
        assert modes['uninstall.sh'] & 0o111

    def test_skip_deb_builds_no_package(self, tarball):
        assert not list(tarball.parent.glob('*.deb'))


@pytest.mark.skipif(not shutil.which('dpkg-deb'), reason='dpkg-deb is not installed')
class TestPackageEdition:
    @pytest.fixture(scope='class')
    def deb(self, tmp_path_factory):
        output = tmp_path_factory.mktemp('dist-deb')
        completed = build(output)
        assert completed.returncode == 0, completed.stderr
        return output / f'temp-file-eraser-tool_{VERSION}_all.deb'

    def test_builds_the_package(self, deb):
        assert deb.exists()

    def test_declares_its_dependencies(self, deb):
        info = subprocess.run(['dpkg-deb', '--field', str(deb)],
                              capture_output=True, text=True, check=True).stdout
        assert f'Version: {VERSION}' in info
        assert 'Architecture: all' in info
        assert 'python3-gi' in info and 'gir1.2-gtk-4.0' in info
        assert 'Recommends: python3-nautilus' in info

    def test_installs_to_the_expected_paths(self, deb):
        contents = subprocess.run(['dpkg-deb', '--contents', str(deb)],
                                  capture_output=True, text=True, check=True).stdout
        for required in ('./usr/bin/temp-file-eraser',
                         './usr/lib/temp-file-eraser/tempfileeraser/__main__.py',
                         './usr/lib/temp-file-eraser/tempfileeraser/rules.json',
                         './usr/share/nautilus-python/extensions/temp-file-eraser-nautilus.py',
                         './usr/share/applications/temp-file-eraser.desktop'):
            assert required in contents, f'{required} is missing from the package'

    def test_does_not_ship_the_unread_scripts_directory(self, deb):
        # Nautilus only reads ~/.local/share/nautilus/scripts, so a system-wide
        # copy would be dead weight that also hides a missing python3-nautilus
        contents = subprocess.run(['dpkg-deb', '--contents', str(deb)],
                                  capture_output=True, text=True, check=True).stdout
        assert '/usr/share/nautilus/scripts' not in contents

    def test_the_payload_runs(self, deb, tmp_path):
        extracted = tmp_path / 'root'
        subprocess.run(['dpkg-deb', '-x', str(deb), str(extracted)], check=True)
        (tmp_path / 'project' / 'node_modules').mkdir(parents=True)
        completed = subprocess.run(
            ['python3', '-m', 'tempfileeraser', str(tmp_path / 'project'), '--list'],
            env={'PATH': '/usr/bin:/bin',
                 'PYTHONPATH': str(extracted / 'usr' / 'lib' / 'temp-file-eraser')},
            capture_output=True, text=True, timeout=60)
        assert completed.returncode == 0, completed.stderr
        assert 'Node.js dependencies' in completed.stdout


class TestVersioning:
    def test_the_version_file_is_x_y_z(self):
        assert VERSION.count('.') == 2
        assert all(part.isdigit() for part in VERSION.split('.'))

    def test_rejects_a_version_that_is_not_x_y_z(self, tmp_path):
        completed = build(tmp_path / 'bad', '--version', 'v1.0', '--skip-deb')
        assert completed.returncode != 0
        assert 'x.y.z' in completed.stderr
