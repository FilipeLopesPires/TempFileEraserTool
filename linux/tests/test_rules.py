"""Mirrors tests/Rules.Tests.ps1, plus the cases where Linux deliberately differs."""

import pytest

from tempfileeraser.rules import (CERTAIN, FILE, FOLDER, UNCERTAIN, Rule, RuleSet,
                                  SiblingSet, default_ruleset, load_ruleset, rule_from_json)


@pytest.fixture(scope='module')
def rules():
    return default_ruleset()


def match(rules, kind, name, siblings=(), path=None):
    return rules.match(kind, name, SiblingSet(siblings), path)


class TestFolderRulesWithoutMarkers:
    @pytest.mark.parametrize('name', [
        'node_modules', '__pycache__', '.pytest_cache', '.next', '.gradle', '.vs',
        '.idea', '.terraform', 'CMakeFiles', '.dart_tool', '.tox', '.swiftpm'])
    def test_matches_anywhere(self, rules, name):
        assert match(rules, FOLDER, name).confidence == CERTAIN

    def test_matches_wildcard_names(self, rules):
        assert match(rules, FOLDER, 'my_package.egg-info').confidence == CERTAIN

    def test_returns_nothing_for_an_ordinary_folder(self, rules):
        assert match(rules, FOLDER, 'src') is None


class TestCaseSensitivity:
    """Windows matches case-insensitively. ext4 is case-sensitive, and so are we."""

    def test_does_not_match_a_different_case(self, rules):
        assert match(rules, FOLDER, 'Node_Modules') is None
        assert match(rules, FOLDER, 'NODE_MODULES') is None

    def test_tells_unity_build_from_node_build(self, rules):
        unity = match(rules, FOLDER, 'Build', ['Build', 'Assets', 'ProjectSettings'])
        node = match(rules, FOLDER, 'build', ['build', 'package.json'])
        assert unity.category == 'Unity player build'
        assert node.category == 'Node.js build output'

    def test_lowercase_build_is_not_a_unity_player_build(self, rules):
        # It falls through to the generic Uncertain rule, so it is listed unchecked
        found = match(rules, FOLDER, 'build', ['build', 'Assets', 'ProjectSettings'])
        assert found.confidence == UNCERTAIN
        assert found.category != 'Unity player build'


class TestFolderRulesWithMarkers:
    @pytest.mark.parametrize('name,marker,category', [
        ('dist', 'package.json', 'Node.js build output'),
        ('bin', 'App.csproj', '.NET build output'),
        ('obj', 'Solution.sln', '.NET build output'),
        ('target', 'Cargo.toml', 'Rust build output'),
        ('target', 'pom.xml', 'Maven build output'),
        ('build', 'build.gradle', 'Gradle build output'),
        ('vendor', 'composer.json', 'PHP Composer dependencies'),
        ('_site', '_config.yml', 'Jekyll site output'),
        ('Pods', 'Podfile', 'CocoaPods dependencies'),
        ('Intermediate', 'Game.uproject', 'Unreal generated files'),
    ])
    def test_matches_next_to_its_marker(self, rules, name, marker, category):
        found = match(rules, FOLDER, name, [name, marker])
        assert found.confidence == CERTAIN
        assert found.category == category

    def test_unity_needs_both_markers(self, rules):
        assert match(rules, FOLDER, 'Library', ['Library', 'Assets']) is None
        assert match(rules, FOLDER, 'Library', ['Library', 'ProjectSettings']) is None
        both = match(rules, FOLDER, 'Library', ['Library', 'Assets', 'ProjectSettings'])
        assert both.category == 'Unity generated files'

    def test_a_folder_with_no_marker_is_not_certain(self, rules):
        assert match(rules, FOLDER, 'vendor', ['vendor']) is None


class TestUncertainRules:
    @pytest.mark.parametrize('name', ['bin', 'obj', 'build', 'dist', 'out', 'target',
                                      'Intermediate', 'Temp', 'DerivedDataCache'])
    def test_generic_names_alone_are_uncertain(self, rules, name):
        found = match(rules, FOLDER, name, [name])
        assert found.confidence == UNCERTAIN

    def test_a_marker_beats_an_uncertain_rule(self, rules):
        found = match(rules, FOLDER, 'target', ['target', 'Cargo.toml'])
        assert found.confidence == CERTAIN


class TestInnerMarkers:
    def test_detects_a_virtual_environment_by_its_config(self, rules, tmp_path):
        venv = tmp_path / 'anything'
        venv.mkdir()
        (venv / 'pyvenv.cfg').write_text('home = /usr')
        found = match(rules, FOLDER, 'anything', ['anything'], venv)
        assert found.category == 'Python virtual environment'

    def test_ignores_a_folder_without_the_config(self, rules, tmp_path):
        plain = tmp_path / 'anything'
        plain.mkdir()
        assert match(rules, FOLDER, 'anything', ['anything'], plain) is None


class TestFileRules:
    @pytest.mark.parametrize('name', ['Thumbs.db', '.DS_Store', 'build.tmp', 'module.pyc',
                                      '.eslintcache', 'npm-debug.log', 'npm-debug.log.1',
                                      'tsconfig.tsbuildinfo', 'crash.dmp', '~$report.docx'])
    def test_matches_temp_files(self, rules, name):
        assert match(rules, FILE, name).confidence == CERTAIN

    @pytest.mark.parametrize('name', ['desktop.ini', 'notes.bak', 'notes.orig', 'notes~',
                                      'main.py', 'README.md'])
    def test_leaves_real_and_backup_files_alone(self, rules, name):
        assert match(rules, FILE, name) is None

    def test_plain_logs_are_uncertain(self, rules):
        assert match(rules, FILE, 'server.log').confidence == UNCERTAIN

    def test_unity_project_files_need_the_unity_markers(self, rules):
        assert match(rules, FILE, 'Game.csproj', ['Game.csproj']) is None
        found = match(rules, FILE, 'Game.csproj', ['Game.csproj', 'Assets', 'ProjectSettings'])
        assert found.category == 'Unity generated project file'


class TestLoading:
    def test_loads_every_rule_from_the_shared_table(self, rules):
        assert len(rules.rules) == 47
        assert sum(1 for rule in rules.rules if rule.kind == FOLDER) == 39
        assert sum(1 for rule in rules.rules if rule.kind == FILE) == 8

    def test_reads_a_single_marker_and_a_marker_group(self, rules):
        unity = next(r for r in rules.rules if r.category == 'Unity generated files')
        dotnet = next(r for r in rules.rules if r.category == '.NET build output')
        assert unity.markers == (('Assets', 'ProjectSettings'),)
        assert dotnet.markers == (('*.csproj',), ('*.fsproj',), ('*.vbproj',), ('*.sln',))

    def test_defaults_omitted_keys(self):
        rule = rule_from_json({'kind': 'Folder', 'category': 'Test'})
        assert rule.names == () and rule.markers == () and rule.confidence == CERTAIN

    @pytest.mark.parametrize('entry', [
        {'kind': 'Directory', 'category': 'Test'},
        {'kind': 'Folder', 'category': 'Test', 'confidence': 'Maybe'},
    ])
    def test_rejects_an_invalid_entry(self, entry):
        with pytest.raises(ValueError):
            rule_from_json(entry)

    def test_a_custom_table_can_replace_the_shipped_one(self, tmp_path):
        path = tmp_path / 'rules.json'
        path.write_text('{"version": 1, "rules": ['
                        '{"kind": "Folder", "category": "Mine", "names": ["scratch"]}]}')
        custom = load_ruleset(path)
        assert custom.match(FOLDER, 'scratch', SiblingSet()).category == 'Mine'
        assert custom.match(FOLDER, 'node_modules', SiblingSet()) is None
