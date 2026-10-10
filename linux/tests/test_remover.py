"""Mirrors tests/Remover.Tests.ps1.

Trashing is exercised two ways. The unit tests replace remover._trash, so they
check our dispatch and error wording without touching any real trash. The
integration test does trash for real, in a subprocess with HOME and XDG_DATA_HOME
pointed at a temporary folder, so GLib resolves an isolated ~/.local/share/Trash.
"""

import os
import subprocess
import sys
import textwrap
import threading
from pathlib import Path

import pytest
from gi.repository import Gio, GLib

from tempfileeraser import remover
from tempfileeraser.jobs import Done, Progress, Removed
from tempfileeraser.remover import (NO_TRASH_HINT, PERMANENT, TRASH, RemovalResult,
                                    format_errors, remove_files, remove_folder, remove_tree,
                                    run_removal, start_removal)


def write(path: Path, size: int = 10) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\0' * size)
    return path


@pytest.fixture
def trash_calls(monkeypatch):
    """Records what would have been trashed, without trashing anything."""
    calls = []
    monkeypatch.setattr(remover, '_trash', calls.append)
    return calls


class TestRemoveTree:
    def test_deletes_a_nested_tree(self, tmp_path):
        write(tmp_path / 'build' / 'a' / 'b' / 'c.o')
        write(tmp_path / 'build' / 'd.o')
        errors = []
        remove_tree(tmp_path / 'build', errors)
        assert errors == []
        assert not (tmp_path / 'build').exists()

    def test_unlinks_symlinks_without_touching_their_target(self, tmp_path):
        keep = write(tmp_path / 'keep' / 'important.txt')
        (tmp_path / 'build').mkdir()
        (tmp_path / 'build' / 'link').symlink_to(tmp_path / 'keep')
        errors = []
        remove_tree(tmp_path / 'build', errors)
        assert errors == []
        assert not (tmp_path / 'build').exists()
        assert keep.exists()

    def test_deletes_a_read_only_file(self, tmp_path):
        target = write(tmp_path / 'build' / 'locked.o')
        target.chmod(0o400)
        (tmp_path / 'build').chmod(0o500)
        errors = []
        try:
            remove_tree(tmp_path / 'build', errors)
        finally:
            if (tmp_path / 'build').exists():
                (tmp_path / 'build').chmod(0o700)
        assert errors == []
        assert not (tmp_path / 'build').exists()

    def test_reports_a_failure_instead_of_raising(self, tmp_path, monkeypatch):
        write(tmp_path / 'build' / 'a.o')
        monkeypatch.setattr(os, 'unlink', _refuse)
        errors = []
        remove_tree(tmp_path / 'build', errors)
        assert errors and 'a.o' in errors[0]


def _refuse(*args, **kwargs):
    raise OSError(13, 'Permission denied')


class TestRemoveFolder:
    def test_succeeds_when_the_folder_is_already_gone(self, tmp_path):
        result = remove_folder(tmp_path / 'gone', PERMANENT)
        assert result.success is True

    def test_erases_permanently(self, tmp_path):
        write(tmp_path / 'node_modules' / 'pkg' / 'index.js')
        result = remove_folder(tmp_path / 'node_modules', PERMANENT)
        assert result.success is True
        assert not (tmp_path / 'node_modules').exists()

    def test_sends_to_the_trash_without_deleting(self, tmp_path, trash_calls):
        target = tmp_path / 'node_modules'
        write(target / 'pkg' / 'index.js')
        result = remove_folder(target, TRASH)
        assert result.success is True
        assert trash_calls == [str(target)]
        assert target.exists()   # the fake trash moved nothing

    def test_explains_a_filesystem_without_a_trash(self, tmp_path, monkeypatch):
        write(tmp_path / 'node_modules' / 'x')

        def no_trash(_path):
            raise GLib.Error.new_literal(Gio.io_error_quark(),
                                         'Unable to find or create trash directory',
                                         int(Gio.IOErrorEnum.NOT_SUPPORTED))

        monkeypatch.setattr(remover, '_trash', no_trash)
        result = remove_folder(tmp_path / 'node_modules', TRASH)
        assert result.success is False
        assert result.error == NO_TRASH_HINT


class TestRemoveFiles:
    def test_deletes_only_the_named_files(self, tmp_path):
        write(tmp_path / 'Thumbs.db')
        write(tmp_path / 'npm-debug.log')
        keep = write(tmp_path / 'main.js')
        result = remove_files(tmp_path, ['Thumbs.db', 'npm-debug.log'], PERMANENT)
        assert result.success is True
        assert not (tmp_path / 'Thumbs.db').exists()
        assert keep.exists()
        assert tmp_path.is_dir()

    def test_ignores_a_file_that_is_already_gone(self, tmp_path):
        assert remove_files(tmp_path, ['vanished.tmp'], PERMANENT).success is True

    def test_reports_the_files_it_could_not_delete(self, tmp_path, monkeypatch):
        write(tmp_path / 'a.tmp')
        monkeypatch.setattr(os, 'unlink', _refuse)
        result = remove_files(tmp_path, ['a.tmp'], PERMANENT)
        assert result.success is False
        assert 'a.tmp' in result.error

    def test_trashes_each_file_in_turn(self, tmp_path, trash_calls):
        write(tmp_path / 'a.tmp')
        write(tmp_path / 'b.tmp')
        remove_files(tmp_path, ['a.tmp', 'b.tmp'], TRASH)
        assert trash_calls == [str(tmp_path / 'a.tmp'), str(tmp_path / 'b.tmp')]


class TestErrorText:
    def test_summarises_several_errors(self):
        assert format_errors(['first']) == 'first'
        assert format_errors(['first', 'second', 'third']) == 'first (and 2 more)'


class TestRunRemoval:
    def test_reports_one_result_per_item(self, tmp_path):
        write(tmp_path / 'a' / 'x')
        write(tmp_path / 'b.tmp')
        items = [
            {'id': 1, 'kind': 'Folder', 'path': str(tmp_path / 'a'), 'bytes': 10},
            {'id': 2, 'kind': 'Files', 'path': str(tmp_path), 'files': ('b.tmp',), 'bytes': 10},
        ]
        job = start_removal(items, PERMANENT)
        job.thread.join(10)
        messages = job.drain()
        results = [m for m in messages if isinstance(m, Removed)]
        assert [r.id for r in results] == [1, 2]
        assert all(r.success for r in results)
        assert isinstance(messages[-1], Done)
        assert not (tmp_path / 'a').exists()
        assert not (tmp_path / 'b.tmp').exists()

    def test_counts_progress_steps(self, tmp_path):
        items = [{'id': i, 'kind': 'Folder', 'path': str(tmp_path / f'gone{i}'), 'bytes': 0}
                 for i in range(3)]
        job = start_removal(items, PERMANENT)
        job.thread.join(10)
        steps = [m.step for m in job.drain() if isinstance(m, Progress)]
        assert steps == [1, 2, 3]

    def test_stops_when_cancelled(self, tmp_path):
        import queue
        write(tmp_path / 'a' / 'x')
        cancel = threading.Event()
        cancel.set()
        message_queue = queue.SimpleQueue()
        cancelled = run_removal([{'id': 1, 'kind': 'Folder', 'path': str(tmp_path / 'a')}],
                                PERMANENT, message_queue, cancel)
        assert cancelled is True
        assert (tmp_path / 'a').exists()


ISOLATED_TRASH = textwrap.dedent('''
    import sys
    sys.path.insert(0, {package!r})
    from tempfileeraser.remover import remove_folder, TRASH
    result = remove_folder({target!r}, TRASH)
    print(result.success, result.error)
''')


class TestRealTrash:
    """The only test that trashes for real, into a throwaway HOME."""

    def test_moves_a_folder_into_the_trash(self, tmp_path):
        home = tmp_path / 'home'
        home.mkdir()
        target = tmp_path / 'work' / 'node_modules'
        write(target / 'pkg' / 'index.js')

        environment = {
            'PATH': '/usr/bin:/bin',
            'HOME': str(home),
            'XDG_DATA_HOME': str(home / '.local' / 'share'),
        }
        package = str(Path(__file__).resolve().parent.parent)
        completed = subprocess.run(
            [sys.executable, '-c', ISOLATED_TRASH.format(package=package, target=str(target))],
            env=environment, capture_output=True, text=True, timeout=60)

        assert completed.returncode == 0, completed.stderr
        assert completed.stdout.startswith('True'), completed.stdout
        assert not target.exists()
        trashed = home / '.local' / 'share' / 'Trash' / 'files' / 'node_modules'
        assert trashed.is_dir()
        assert (trashed / 'pkg' / 'index.js').exists()
        info = home / '.local' / 'share' / 'Trash' / 'info' / 'node_modules.trashinfo'
        assert 'Path=' in info.read_text()
