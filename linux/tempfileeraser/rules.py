"""Rules that decide which folders and files are regenerable temp, cache or build output.

Ported from src/TempFolderRules.ps1. The table itself is rules.json, shared with
the Windows edition so one change updates both.

A rule matches by name, optionally only when "marker" files sit next to the
candidate (bin/obj only beside a *.csproj). Markers is a list of alternatives; an
alternative that is itself a list needs all of its entries. Uncertain rules only
apply when no Certain rule matched, and their rows start unchecked in the review
window.

One deliberate difference from Windows: matching is case-sensitive, because ext4
is. That is also what keeps Unity's Build apart from Node's build.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Iterable, Sequence

FOLDER = 'Folder'
FILE = 'File'
CERTAIN = 'Certain'
UNCERTAIN = 'Uncertain'

_WILDCARD = re.compile(r'[*?]')
_EXTENSION_ONLY = re.compile(r'\*(\.[^*?]+)\Z')


@dataclass(frozen=True)
class Rule:
    kind: str
    category: str
    names: tuple[str, ...] = ()
    markers: tuple[tuple[str, ...], ...] = ()
    inner_markers: tuple[str, ...] = ()
    confidence: str = CERTAIN


@dataclass(frozen=True)
class Match:
    """Why a folder or file is listed.

    note carries a reason the plain category cannot: a generated folder sitting
    directly in $HOME is a global tool cache rather than project output.
    """

    category: str
    confidence: str
    note: str | None = None


class SiblingSet:
    """The names of everything in one folder, used to check markers for its children."""

    __slots__ = ('names', '_pattern_cache')

    def __init__(self, names: Iterable[str] = ()):
        self.names = set(names)
        self._pattern_cache: dict[str, bool] = {}

    def has(self, pattern: str) -> bool:
        if not _WILDCARD.search(pattern):
            return pattern in self.names
        found = self._pattern_cache.get(pattern)
        if found is None:
            found = any(fnmatchcase(name, pattern) for name in self.names)
            self._pattern_cache[pattern] = found
        return found


@dataclass(frozen=True)
class _Prefixed:
    prefix: str
    pattern: str
    rule: Rule


class _KindIndex:
    """Each rule name in the cheapest lookup that can find it.

    Exact names and "*.ext" patterns go in dicts; anything else is checked by
    literal prefix before the full pattern. Scans visit every file outside matched
    folders, so testing each one against every pattern would be slow.
    """

    __slots__ = ('exact', 'extension', 'prefixed', 'inner')

    def __init__(self) -> None:
        self.exact: dict[str, list[Rule]] = {}
        self.extension: dict[str, list[Rule]] = {}
        self.prefixed: list[_Prefixed] = []
        self.inner: list[Rule] = []

    def add(self, rule: Rule) -> None:
        if rule.inner_markers:
            self.inner.append(rule)
        for name in rule.names:
            extension = _EXTENSION_ONLY.fullmatch(name)
            if not _WILDCARD.search(name):
                self.exact.setdefault(name, []).append(rule)
            elif extension:
                self.extension.setdefault(extension.group(1), []).append(rule)
            else:
                self.prefixed.append(_Prefixed(_WILDCARD.split(name, 1)[0], name, rule))

    def candidates(self, name: str) -> list[Rule]:
        rules = list(self.exact.get(name, ()))
        dot = name.rfind('.')
        if dot >= 0:
            rules.extend(self.extension.get(name[dot:], ()))
        rules.extend(
            candidate.rule
            for candidate in self.prefixed
            if name.startswith(candidate.prefix) and fnmatchcase(name, candidate.pattern)
        )
        return rules


class RuleSet:
    """The rule table plus its lookup index."""

    def __init__(self, rules: Sequence[Rule]):
        self.rules = tuple(rules)
        self._index = {FOLDER: _KindIndex(), FILE: _KindIndex()}
        for rule in self.rules:
            self._index[rule.kind].add(rule)

    def match(self, kind: str, name: str, siblings: SiblingSet,
              path: str | Path | None = None) -> Match | None:
        """The Match for a folder or file, or None when it is not regenerable.

        siblings is the parent folder's entries, the candidate included. path is
        only needed for folder rules that look inside the candidate.
        """
        index = self._index[kind]
        uncertain: Rule | None = None
        for rule in index.candidates(name):
            if rule.confidence == UNCERTAIN:
                if uncertain is None:
                    uncertain = rule
            elif _markers_present(rule, siblings):
                return Match(rule.category, CERTAIN)

        if path is not None:
            base = Path(path)
            for rule in index.inner:
                if all(_is_file(base / marker) for marker in rule.inner_markers):
                    return Match(rule.category, CERTAIN)

        if uncertain is not None:
            return Match(uncertain.category, UNCERTAIN)
        return None


def _is_file(path: Path) -> bool:
    # Path.is_file() only swallows "not found" errors; an unreadable folder raises
    try:
        return path.is_file()
    except OSError:
        return False


def _markers_present(rule: Rule, siblings: SiblingSet) -> bool:
    if not rule.markers:
        return True
    return any(all(siblings.has(pattern) for pattern in alternative)
               for alternative in rule.markers)


def _as_names(value) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,)
    return tuple(str(name) for name in value)


def _as_markers(value) -> tuple[tuple[str, ...], ...]:
    # An alternative is one pattern, or a list of patterns that must all be present
    if value is None:
        return ()
    return tuple(_as_names(alternative) for alternative in value)


def rule_from_json(entry: dict) -> Rule:
    """One rules.json entry. Omitted keys take their defaults."""
    kind = entry['kind']
    if kind not in (FOLDER, FILE):
        raise ValueError(f'rules.json: kind must be Folder or File, not {kind!r}')
    confidence = entry.get('confidence', CERTAIN)
    if confidence not in (CERTAIN, UNCERTAIN):
        raise ValueError(f'rules.json: confidence must be Certain or Uncertain, not {confidence!r}')
    return Rule(
        kind=kind,
        category=entry['category'],
        names=_as_names(entry.get('names')),
        markers=_as_markers(entry.get('markers')),
        inner_markers=_as_names(entry.get('innerMarkers')),
        confidence=confidence,
    )


def default_rules_path() -> Path:
    """rules.json: beside the package once installed, in ../../rules in a clone."""
    here = Path(__file__).resolve().parent
    for candidate in (here / 'rules.json', here.parent.parent / 'rules' / 'rules.json'):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError('rules.json was not found beside the package or in ../../rules')


def load_ruleset(path: str | Path | None = None) -> RuleSet:
    document = json.loads(Path(path or default_rules_path()).read_text(encoding='utf-8'))
    return RuleSet([rule_from_json(entry) for entry in document['rules']])


_default: RuleSet | None = None


def default_ruleset() -> RuleSet:
    global _default
    if _default is None:
        _default = load_ruleset()
    return _default
