"""Mirrors tests/Scanner.Tests.ps1, plus the Linux-only behaviours."""

import os
import queue
import threading
from pathlib import Path

import pytest

from tempfileeraser import scanner
from tempfileeraser.jobs import FoundFiles, FoundFolder, Progress, Size
from tempfileeraser.rules import CERTAIN, UNCERTAIN
from tempfileeraser.scanner import (find_protected_zone, folder_size, is_large_scan_root,
                                    protected_zones, resolve_scan_root, scan, start_scan)


def write(path: Path, size: int = 10) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\0' * size)
    return path


def run_scan(root, cancel=None, **options):
    """Scans synchronously and returns every message it produced."""
    options.setdefault('zones', ())
    options.setdefault('home', Path(root) / '.no-such-home')
    message_queue: queue.SimpleQueue = queue.SimpleQueue()
    cancelled = scan(root, message_queue, cancel or threading.Event(), **options)
    messages = []
    while True:
        try:
            messages.append(message_queue.get_nowait())
        except queue.Empty:
            return messages, cancelled


def paths_of(messages, message_type=FoundFolder):
    return {message.path for message in messages if isinstance(message, message_type)}


@pytest.fixture
def tree(tmp_path):
    write(tmp_path / 'web' / 'package.json')
    write(tmp_path / 'web' / 'node_modules' / 'left-pad' / 'index.js', 100)
    write(tmp_path / 'web' / 'node_modules' / 'left-pad' / 'node_modules' / 'inner' / 'i.js', 50)
    write(tmp_path / 'web' / 'dist' / 'app.js', 30)
    write(tmp_path / 'web' / 'src' / 'main.js')
    write(tmp_path / 'web' / 'npm-debug.log', 7)
    write(tmp_path / 'web' / 'Thumbs.db', 3)
    write(tmp_path / 'web' / 'server.log', 5)
    write(tmp_path / '.git' / 'objects' / 'node_modules' / 'x')
    write(tmp_path / 'docs' / 'build' / 'page.html')
    write(tmp_path / 'py' / '.venv' / 'pyvenv.cfg')
    return tmp_path


class TestScan:
    def test_reports_generated_folders(self, tree):
        messages, _ = run_scan(tree)
        found = paths_of(messages)
        assert str(tree / 'web' / 'node_modules') in found
        assert str(tree / 'web' / 'dist') in found
        assert str(tree / 'py' / '.venv') in found

    def test_does_not_descend_into_a_matched_folder(self, tree):
        messages, _ = run_scan(tree)
        nested = str(tree / 'web' / 'node_modules' / 'left-pad' / 'node_modules')
        assert nested not in paths_of(messages)

    def test_never_reports_the_root_itself(self, tree):
        messages, _ = run_scan(tree)
        assert str(tree) not in paths_of(messages)

    def test_skips_version_control_folders(self, tree):
        messages, _ = run_scan(tree)
        assert not any('.git' in path for path in paths_of(messages))

    def test_lists_an_unexplained_build_folder_as_uncertain(self, tree):
        messages, _ = run_scan(tree)
        build = next(m for m in messages
                     if isinstance(m, FoundFolder) and m.path.endswith('docs/build'))
        assert build.confidence == UNCERTAIN

    def test_groups_temp_files_by_folder_and_confidence(self, tree):
        messages, _ = run_scan(tree)
        groups = {(m.path, m.confidence): m for m in messages if isinstance(m, FoundFiles)}
        certain = groups[(str(tree / 'web'), CERTAIN)]
        uncertain = groups[(str(tree / 'web'), UNCERTAIN)]
        assert set(certain.files) == {'npm-debug.log', 'Thumbs.db'}
        assert certain.bytes == 10
        assert set(uncertain.files) == {'server.log'}

    def test_sizes_every_matched_folder(self, tree):
        messages, _ = run_scan(tree)
        sizes = {m.id: m for m in messages if isinstance(m, Size)}
        folders = {m.id: m for m in messages if isinstance(m, FoundFolder)}
        assert set(sizes) == set(folders)
        node_modules = next(i for i, m in folders.items() if m.path.endswith('node_modules'))
        assert sizes[node_modules].bytes == 150
        assert sizes[node_modules].files == 2

    def test_reports_progress(self, tree):
        messages, _ = run_scan(tree)
        assert any(isinstance(m, Progress) for m in messages)

    def test_ids_are_unique(self, tree):
        messages, _ = run_scan(tree)
        ids = [m.id for m in messages if isinstance(m, (FoundFolder, FoundFiles))]
        assert len(ids) == len(set(ids))


class TestBoundaries:
    def test_skips_protected_zones(self, tmp_path):
        write(tmp_path / 'protected' / 'node_modules' / 'x')
        write(tmp_path / 'mine' / 'node_modules' / 'y')
        messages, _ = run_scan(tmp_path, zones=(tmp_path / 'protected',))
        found = paths_of(messages)
        assert str(tmp_path / 'mine' / 'node_modules') in found
        assert not any(path.startswith(str(tmp_path / 'protected')) for path in found)

    def test_does_not_follow_symlinked_folders(self, tmp_path):
        write(tmp_path / 'outside' / 'node_modules' / 'x')
        (tmp_path / 'inside').mkdir()
        (tmp_path / 'inside' / 'link').symlink_to(tmp_path / 'outside')
        messages, _ = run_scan(tmp_path / 'inside')
        assert paths_of(messages) == set()

    def test_does_not_report_a_symlink_that_is_itself_a_match(self, tmp_path):
        write(tmp_path / 'real' / 'x')
        (tmp_path / 'project').mkdir()
        (tmp_path / 'project' / 'node_modules').symlink_to(tmp_path / 'real')
        messages, _ = run_scan(tmp_path / 'project')
        assert paths_of(messages) == set()

    def test_stays_on_the_filesystem_it_started_on(self, tmp_path, monkeypatch):
        write(tmp_path / 'local' / 'node_modules' / 'x')
        write(tmp_path / 'mounted' / 'node_modules' / 'y')
        real_device = scanner.entry_device

        def fake_device(entry):
            return 999 if entry.name == 'mounted' else real_device(entry)

        monkeypatch.setattr(scanner, 'entry_device', fake_device)
        found = paths_of(run_scan(tmp_path)[0])
        assert str(tmp_path / 'local' / 'node_modules') in found
        assert not any('mounted' in path for path in found)

    def test_lists_a_generated_folder_in_home_as_a_global_cache(self, tmp_path):
        write(tmp_path / '.gradle' / 'caches' / 'x')
        write(tmp_path / 'projects' / 'app' / '.gradle' / 'y')
        messages, _ = run_scan(tmp_path, home=tmp_path)
        by_path = {m.path: m for m in messages if isinstance(m, FoundFolder)}
        global_cache = by_path[str(tmp_path / '.gradle')]
        project_cache = by_path[str(tmp_path / 'projects' / 'app' / '.gradle')]
        assert global_cache.confidence == UNCERTAIN
        assert global_cache.note == scanner.GLOBAL_CACHE_NOTE
        assert project_cache.confidence == CERTAIN
        assert project_cache.note is None

    def test_survives_an_unreadable_folder(self, tmp_path):
        write(tmp_path / 'open' / 'node_modules' / 'x')
        closed = tmp_path / 'closed'
        closed.mkdir()
        write(closed / 'node_modules' / 'y')
        closed.chmod(0o000)
        try:
            found = paths_of(run_scan(tmp_path)[0])
        finally:
            closed.chmod(0o700)
        assert str(tmp_path / 'open' / 'node_modules') in found


class TestCancellation:
    def test_stops_when_cancelled(self, tree):
        cancel = threading.Event()
        cancel.set()
        messages, cancelled = run_scan(tree, cancel=cancel)
        assert cancelled is True
        assert paths_of(messages) == set()

    def test_start_scan_runs_in_the_background_and_stops(self, tree):
        job = start_scan(tree, zones=(), home=tree / '.no-such-home')
        job.thread.join(10)
        assert not job.thread.is_alive()
        kinds = {type(message) for message in job.drain()}
        assert FoundFolder in kinds
        job.stop()


class TestFolderSize:
    def test_counts_a_hardlinked_file_once(self, tmp_path):
        original = write(tmp_path / 'store' / 'original.bin', 4000)
        os.link(original, tmp_path / 'store' / 'linked.bin')
        size = folder_size(tmp_path / 'store', threading.Event())
        assert size.bytes == 4000
        assert size.files == 1

    def test_does_not_follow_symlinks(self, tmp_path):
        write(tmp_path / 'target' / 'big.bin', 5000)
        (tmp_path / 'store').mkdir()
        (tmp_path / 'store' / 'link').symlink_to(tmp_path / 'target')
        assert folder_size(tmp_path / 'store', threading.Event()).bytes == 0

    def test_returns_nothing_when_cancelled(self, tmp_path):
        write(tmp_path / 'store' / 'a.bin')
        cancel = threading.Event()
        cancel.set()
        assert folder_size(tmp_path / 'store', cancel) is None


class TestZonesAndRoots:
    def test_protected_zones_cover_system_and_user_state(self):
        zones = protected_zones(Path('/home/someone'))
        assert Path('/usr') in zones
        assert Path('/home/someone/.local/share') in zones
        assert Path('/home/someone/.var/app') in zones

    @pytest.mark.parametrize('path,expected', [
        ('/usr/lib/node_modules', '/usr'),
        ('/etc', '/etc'),
        ('/home/someone/.cache/pip', '/home/someone/.cache'),
        ('/home/someone/projects', None),
    ])
    def test_finds_the_zone_that_contains_a_path(self, path, expected):
        zone = find_protected_zone(Path(path), protected_zones(Path('/home/someone')))
        assert zone == (Path(expected) if expected else None)

    def test_recognises_large_scan_roots(self, tmp_path):
        assert is_large_scan_root(Path('/'), tmp_path)
        assert is_large_scan_root(Path('/home'), tmp_path)
        assert is_large_scan_root(tmp_path, tmp_path)
        assert not is_large_scan_root(tmp_path / 'projects', tmp_path)

    def test_resolve_scan_root_rejects_a_file(self, tmp_path):
        target = write(tmp_path / 'notes.txt')
        with pytest.raises(ValueError):
            resolve_scan_root(str(target))

    def test_resolve_scan_root_rejects_a_missing_folder(self, tmp_path):
        with pytest.raises(ValueError):
            resolve_scan_root(str(tmp_path / 'nope'))

    def test_resolve_scan_root_normalises(self, tmp_path):
        (tmp_path / 'projects').mkdir()
        assert resolve_scan_root(f'  {tmp_path}/projects/  ') == tmp_path / 'projects'
