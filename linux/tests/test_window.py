"""Review window tests. Need a display: CI runs them under xvfb-run.

The erase path is exercised with Erase permanently, driven straight through
_start_erase. Trashing for real belongs in test_remover.py, where a subprocess can
give GLib an isolated HOME; in-process it would reach the developer's own Trash.
"""

import os
from pathlib import Path

import pytest

gtk = pytest.importorskip('gi.repository.Gtk')

import gi  # noqa: E402

gi.require_version('Gtk', '4.0')
from gi.repository import GLib, Gtk  # noqa: E402

from tempfileeraser.jobs import Removed  # noqa: E402
from tempfileeraser.remover import PERMANENT  # noqa: E402
from tempfileeraser.window import ReviewWindow, RowObject  # noqa: E402

pytestmark = pytest.mark.skipif(
    not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')),
    reason='needs a display; run under xvfb-run')


def write(path: Path, size: int = 10) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\0' * size)
    return path


def pump_until(predicate, timeout: float = 20.0) -> bool:
    """Runs the GTK main loop until predicate holds, the way a user's clicks would."""
    context = GLib.MainContext.default()
    deadline = GLib.get_monotonic_time() + int(timeout * 1_000_000)
    while not predicate():
        if GLib.get_monotonic_time() > deadline:
            return False
        context.iteration(False)
    return True


@pytest.fixture(scope='module')
def application():
    if not Gtk.init_check():
        pytest.skip('GTK could not open a display')
    app = Gtk.Application(application_id='io.github.filipelopespires.TempFileEraser.Tests',
                          flags=1 << 5)   # NON_UNIQUE
    app.register()
    yield app


@pytest.fixture
def project(tmp_path):
    write(tmp_path / 'package.json')
    write(tmp_path / 'node_modules' / 'pkg' / 'index.js', 400)
    write(tmp_path / 'src' / 'main.js')
    write(tmp_path / 'docs' / 'build' / 'page.html', 50)
    write(tmp_path / 'server.log', 20)
    return tmp_path


@pytest.fixture
def window(application, project):
    window = ReviewWindow(application, str(project))
    assert pump_until(lambda: window.phase != 'Scanning'), 'the scan never finished'
    yield window
    window.phase = 'Finished'
    if window.job:
        window.job.stop()
    window.destroy()


def rows_of(window):
    return [window.store.get_item(i).row for i in range(window.store.get_n_items())]


class TestScanPhase:
    def test_lists_what_the_scan_found(self, window):
        names = {Path(row.path).name for row in rows_of(window)}
        assert 'node_modules' in names

    def test_becomes_ready_and_hides_stop(self, window):
        assert window.phase == 'Ready'
        assert window.stop.get_visible() is False
        assert 'Scan complete' in window.status.get_text()

    def test_header_counts_the_findings(self, window):
        assert window.header.get_text().startswith(f'Found {window.store.get_n_items()} item')

    def test_certain_rows_start_checked_and_uncertain_ones_do_not(self, window):
        by_name = {Path(row.path).name: row for row in rows_of(window)}
        assert by_name['node_modules'].checked is True
        assert by_name['build'].checked is False

    def test_totals_reflect_the_selection(self, window):
        checked = [row for row in rows_of(window) if row.checked]
        text = window.total.get_text()
        assert text.startswith(f'Selected {len(checked)} of ')

    def test_erase_is_enabled_once_ready(self, window):
        assert window.erase.get_sensitive() is True

    def test_every_row_has_a_size(self, window):
        assert all(row.bytes is not None for row in rows_of(window))


class TestSelection:
    def test_select_all_checks_everything(self, window):
        window.select_all.set_active(True)
        assert all(row.checked for row in rows_of(window))
        assert window.erase.get_sensitive() is True

    def test_clearing_select_all_disables_erase(self, window):
        window.select_all.set_active(True)
        window.select_all.set_active(False)
        assert not any(row.checked for row in rows_of(window))
        assert window.erase.get_sensitive() is False

    def test_unchecking_one_row_updates_the_total(self, window):
        target = next(obj for obj in (window.store.get_item(i)
                                      for i in range(window.store.get_n_items()))
                      if obj.row.checked)
        before = window.total.get_text()
        target.set_property('checked', False)
        window._update_totals()
        assert window.total.get_text() != before


class TestModeNote:
    def test_explains_each_mode(self, window):
        window.permanent.set_active(True)
        assert 'cannot be recovered' in window.mode_note.get_text()
        window.trash.set_active(True)
        assert 'empty the Trash' in window.mode_note.get_text()


class TestErase:
    def test_erases_permanently_and_reports(self, window, project):
        targets = [row for row in rows_of(window) if row.checked]
        window._start_erase(targets, PERMANENT)
        assert window.phase == 'Erasing'
        assert pump_until(lambda: window.phase == 'Finished'), 'the removal never finished'

        assert not (project / 'node_modules').exists()
        assert (project / 'src' / 'main.js').exists()      # untouched
        assert (project / 'docs' / 'build').exists()        # was unchecked
        assert len(window.results) == len(targets)
        assert all(isinstance(result, Removed) and result.success
                   for result in window.results)

    def test_refuses_to_close_mid_erase(self, window):
        window.phase = 'Erasing'
        assert window._on_close_request(window) is True


class TestEmptyScan:
    def test_says_when_nothing_was_found(self, application, tmp_path):
        write(tmp_path / 'src' / 'main.js')
        window = ReviewWindow(application, str(tmp_path))
        assert pump_until(lambda: window.phase == 'Finished')
        assert window.store.get_n_items() == 0
        window.destroy()


class TestRowObject:
    def test_size_text_follows_the_row(self, project):
        from tempfileeraser.model import FOLDER_ROW, Row
        obj = RowObject(Row(id=0, kind=FOLDER_ROW, path='/p', category='c', confidence='Certain'))
        assert obj.props.size_text.startswith('Calculating')
        obj.row.bytes = 2048
        assert obj.props.size_text == '2.0 KB'

    def test_checked_proxies_to_the_row(self, project):
        from tempfileeraser.model import FOLDER_ROW, Row
        obj = RowObject(Row(id=0, kind=FOLDER_ROW, path='/p', category='c', confidence='Certain'))
        obj.set_property('checked', True)
        assert obj.row.checked is True
