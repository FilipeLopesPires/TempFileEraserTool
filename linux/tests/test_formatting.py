"""Mirrors the Format-* cases in tests/Clear-TempFolders.Tests.ps1."""

import pytest

from tempfileeraser.formatting import (EraseSummary, SelectionSummary, format_byte_size,
                                       format_count, format_erase_summary, format_name_list,
                                       format_row_type, format_selection_summary,
                                       selection_summary)
from tempfileeraser.jobs import Removed
from tempfileeraser.model import FILES_ROW, FOLDER_ROW, Row
from tempfileeraser.rules import CERTAIN, UNCERTAIN


def folder_row(**overrides):
    row = Row(id=0, kind=FOLDER_ROW, path='/p', category='Node.js dependencies',
              confidence=CERTAIN)
    for key, value in overrides.items():
        setattr(row, key, value)
    return row


def files_row(names, confidence=CERTAIN):
    return Row(id=0, kind=FILES_ROW, path='/p', category='Temporary file',
               confidence=confidence, files=tuple(names), bytes=0)


class TestFormatCount:
    @pytest.mark.parametrize('count,expected', [(0, '0 items'), (1, '1 item'), (5, '5 items')])
    def test_pluralises(self, count, expected):
        assert format_count(count, 'item') == expected

    def test_takes_an_irregular_plural(self):
        assert format_count(2, 'entry', 'entries') == '2 entries'


class TestFormatByteSize:
    @pytest.mark.parametrize('size,expected', [
        (0, '0 bytes'),
        (1, '1 bytes'),
        (1023, '1023 bytes'),
        (1024, '1.0 KB'),
        (1536, '1.5 KB'),
        (1024 ** 2, '1.0 MB'),
        (5 * 1024 ** 3, '5.0 GB'),
        (3 * 1024 ** 4, '3.0 TB'),
    ])
    def test_scales_to_the_right_unit(self, size, expected):
        assert format_byte_size(size) == expected

    def test_stays_in_terabytes_above_a_petabyte(self):
        assert format_byte_size(2048 * 1024 ** 4).endswith(' TB')


class TestFormatNameList:
    def test_lists_every_name_when_there_are_few(self):
        assert format_name_list(['a', 'b']) == '   - a\n   - b'

    def test_truncates_a_long_list(self):
        text = format_name_list([f'f{i}' for i in range(20)])
        assert text.count('\n') == 15
        assert text.endswith('   ... and 5 more')


class TestFormatRowType:
    def test_names_a_certain_folder_by_its_category(self):
        assert format_row_type(folder_row()) == 'Node.js dependencies'

    def test_explains_an_uncertain_folder(self):
        row = folder_row(category='Possible build output', confidence=UNCERTAIN)
        assert format_row_type(row) == 'Possible build output (no project file found)'

    def test_prefers_a_note_over_the_generic_explanation(self):
        row = folder_row(confidence=UNCERTAIN, note='global tool cache, not project output')
        assert format_row_type(row) == 'Node.js dependencies (global tool cache, not project output)'

    def test_counts_temp_files(self):
        assert format_row_type(files_row(['a.tmp', 'b.tmp'])) == '2 temp files: a.tmp, b.tmp'

    def test_truncates_a_long_file_list(self):
        text = format_row_type(files_row(['a', 'b', 'c', 'd']))
        assert text == '4 temp files: a, b, c, …'

    def test_marks_uncertain_files_as_possible(self):
        assert format_row_type(files_row(['x.log'], UNCERTAIN)) == '1 possible temp file: x.log'


class TestSelectionSummary:
    def test_counts_only_checked_rows(self):
        rows = [folder_row(checked=True, bytes=100), folder_row(checked=False, bytes=900)]
        summary = selection_summary(rows)
        assert (summary.total, summary.selected, summary.bytes) == (2, 1, 100)

    def test_counts_rows_whose_size_is_unknown(self):
        rows = [folder_row(checked=True, bytes=None), folder_row(checked=True, bytes=50)]
        summary = selection_summary(rows)
        assert (summary.selected, summary.bytes, summary.unsized) == (2, 50, 1)

    def test_handles_an_empty_list(self):
        assert selection_summary([]) == SelectionSummary(0, 0, 0, 0)


class TestFormatSelectionSummary:
    def test_omits_the_size_when_nothing_is_selected(self):
        assert format_selection_summary(SelectionSummary(4, 0, 0, 0)) == 'Selected 0 of 4 items'

    def test_shows_the_total_size(self):
        text = format_selection_summary(SelectionSummary(4, 2, 2048, 0))
        assert text == 'Selected 2 of 4 items · 2.0 KB'

    def test_says_when_sizes_are_still_being_calculated(self):
        text = format_selection_summary(SelectionSummary(4, 2, 2048, 1), still_scanning=True)
        assert text.endswith('at least 2.0 KB (still calculating)')

    def test_says_when_sizes_are_unknown_after_the_scan(self):
        text = format_selection_summary(SelectionSummary(4, 2, 2048, 1), still_scanning=False)
        assert text.endswith('at least 2.0 KB (some sizes unknown)')


class TestFormatEraseSummary:
    def test_reports_a_trash_run(self):
        results = [Removed(id=1, path='/a', success=True, bytes=2048)]
        summary = format_erase_summary(results, 'Trash')
        assert summary.icon == 'information'
        assert 'Moved 1 item to the Trash (2.0 KB)' in summary.text
        assert 'Empty the Trash to free the space.' in summary.text

    def test_reports_a_permanent_run(self):
        results = [Removed(id=1, path='/a', success=True, bytes=1024),
                   Removed(id=2, path='/b', success=True, bytes=1024)]
        summary = format_erase_summary(results, 'Permanent')
        assert summary.text == 'Erased 2 items, freeing 2.0 KB.'

    def test_lists_failures_and_warns(self):
        results = [Removed(id=1, path='/a', success=True, bytes=1024),
                   Removed(id=2, path='/b', success=False, error='in use')]
        summary = format_erase_summary(results, 'Permanent')
        assert summary.icon == 'warning'
        assert 'Could not remove 1 item' in summary.text
        assert '   - /b: in use' in summary.text

    def test_says_when_nothing_was_removed(self):
        summary = format_erase_summary([], 'Trash')
        assert summary.text == 'Nothing was removed.'

    def test_appends_scan_errors(self):
        summary = format_erase_summary([], 'Trash', errors=['disk fell off'])
        assert summary.text.endswith('Error: disk fell off')
        assert summary.icon == 'warning'

    def test_ignores_unknown_sizes_in_the_total(self):
        results = [Removed(id=1, path='/a', success=True, bytes=None),
                   Removed(id=2, path='/b', success=True, bytes=1024)]
        assert 'freeing 1.0 KB' in format_erase_summary(results, 'Permanent').text
