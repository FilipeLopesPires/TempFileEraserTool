"""The --list mode, which is also how the core is exercised without a display."""

from pathlib import Path

import pytest

from tempfileeraser.__main__ import collect, list_findings, main, parse_args


def write(path: Path, size: int = 10) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\0' * size)
    return path


@pytest.fixture
def project(tmp_path):
    write(tmp_path / 'package.json')
    write(tmp_path / 'node_modules' / 'pkg' / 'index.js', 500)
    write(tmp_path / 'src' / 'main.js')
    write(tmp_path / 'server.log', 20)
    return tmp_path


class TestArguments:
    def test_accepts_dry_run_as_an_alias_for_list(self):
        assert parse_args(['/tmp', '--dry-run']).list_only is True
        assert parse_args(['/tmp', '--list']).list_only is True

    def test_defaults_to_the_review_window(self):
        assert parse_args(['/tmp']).list_only is False


class TestCollect:
    def test_returns_sized_rows(self, project):
        rows, errors, cancelled = collect(project, zones=(), home=project / '.nohome')
        assert errors == [] and cancelled is False
        node_modules = next(row for row in rows if row.path.endswith('node_modules'))
        assert node_modules.bytes == 500
        assert node_modules.checked is True

    def test_leaves_uncertain_rows_unchecked(self, project):
        rows, _, _ = collect(project, zones=(), home=project / '.nohome')
        logs = next(row for row in rows if row.files and 'server.log' in row.files)
        assert logs.checked is False


class TestListFindings:
    def test_prints_a_row_per_finding(self, project, capsys):
        assert list_findings(project) == 0
        output = capsys.readouterr().out
        assert 'node_modules' in output
        assert 'Node.js dependencies' in output
        assert '2 items found' in output

    def test_marks_unchecked_rows(self, project, capsys):
        list_findings(project)
        lines = [line for line in capsys.readouterr().out.splitlines() if 'server.log' in line]
        assert lines and lines[0].startswith('-')

    def test_says_when_nothing_was_found(self, tmp_path, capsys):
        write(tmp_path / 'src' / 'main.js')
        assert list_findings(tmp_path) == 0
        assert 'No temp, cache or build folders or files were found' in capsys.readouterr().out


class TestMain:
    def test_refuses_a_protected_location(self, capsys):
        assert main(['/usr', '--list']) == 1
        assert 'protected location' in capsys.readouterr().err

    def test_refuses_a_missing_folder(self, tmp_path, capsys):
        assert main([str(tmp_path / 'nope'), '--list']) == 1
        assert 'Folder not found' in capsys.readouterr().err

    def test_needs_a_path_for_the_review_window(self, capsys):
        assert main([]) == 2
        assert 'No folder was given' in capsys.readouterr().err

    def test_lists_the_current_folder_when_none_is_given(self, project, monkeypatch, capsys):
        monkeypatch.chdir(project)
        assert main(['--list']) == 0
        assert 'node_modules' in capsys.readouterr().out

    def test_warns_before_scanning_a_large_root(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setattr('tempfileeraser.__main__.is_large_scan_root', lambda path: True)
        assert main([str(tmp_path), '--list']) == 0
        assert 'may take a long time' in capsys.readouterr().err
