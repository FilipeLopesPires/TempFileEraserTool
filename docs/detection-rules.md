# Detection rules

Everything the tool considers erasable is described by [rules/rules.json](../rules/rules.json).
Both platforms read that one file, so adding support for a new framework usually means adding
one entry and nothing else.

## The file

```json
{
  "version": 1,
  "rules": [
    { "kind": "Folder", "category": "Node.js dependencies", "names": ["node_modules"] },
    { "kind": "Folder", "category": "Unity generated files",
      "names": ["Library", "Temp", "Obj", "Logs"],
      "markers": [["Assets", "ProjectSettings"]] },
    { "kind": "File", "category": "Log file", "names": ["*.log"], "confidence": "Uncertain" }
  ]
}
```

| Key | Required | Meaning |
|---|---|---|
| `kind` | yes | `"Folder"` or `"File"` |
| `category` | yes | Shown in the Type column, so write it for a reader |
| `names` | no | Names or glob patterns to match. Defaults to none |
| `markers` | no | What must sit *beside* the candidate. Defaults to none |
| `innerMarkers` | no | What must sit *inside* the candidate. Defaults to none |
| `confidence` | no | `"Certain"` (default) or `"Uncertain"` |

Omitted keys take their defaults, which is why most entries are one line.

### names

Plain names match exactly. Globs support `*` and `?`:

```json
"names": ["*.egg-info", "cmake-build-*", "npm-debug.log*", "~$*.doc*"]
```

**Do not use character classes** (`[0-9]`). Both implementations bucket patterns by their
literal prefix for speed, and a `[` lands in that prefix where it will never match. A pattern
like `core.[0-9]*` silently matches nothing.

### markers — "only when this is next to it"

`markers` is a list of *alternatives*; any one of them is enough. An alternative that is
itself a list requires all of its entries.

```json
"markers": ["*.csproj", "*.sln"]              // either one will do
"markers": [["Assets", "ProjectSettings"]]    // both must be present
```

This is what makes generic names safe. `bin` is deleted next to a `.csproj` and left alone
otherwise. Markers are matched against the names in the candidate's own folder, which the
scanner has already collected, so they cost nothing to check.

### innerMarkers — "only when this is inside it"

For folders whose name tells you nothing but whose contents do. The only current use is
Python virtual environments, which is how `venv`, `.venv`, `env` and whatever else the user
called it are all caught by one rule:

```json
{ "kind": "Folder", "category": "Python virtual environment",
  "names": [], "innerMarkers": ["pyvenv.cfg"] }
```

Inner markers hit the disk, so they are checked last, only after every name rule has failed.

### confidence

`Certain` rows start checked. `Uncertain` rows are listed, greyed out, unchecked, and
annotated *(no project file found)*. Use `Uncertain` when a name is probably generated but
you would not bet someone's work on it — the generic `bin`, `obj`, `build`, `dist`, `out`,
`target` and `Temp` entries are all of this kind.

An `Uncertain` rule never beats a `Certain` one: the matcher remembers the first uncertain
hit, keeps looking, and only falls back to it if nothing certain matched.

## How matching works

Order matters. Rules are evaluated in file order, and the first `Certain` rule whose markers
are satisfied wins.

For speed, names are sorted into three buckets when the table loads:

| Bucket | Holds | Looked up by |
|---|---|---|
| exact | names with no wildcard | dictionary hit |
| extension | patterns of the form `*.ext` | dictionary hit on the last dot |
| prefixed | everything else | literal prefix, then the full glob |

This matters because a scan tests every file it passes that is not inside a matched folder.
Checking each one against all 113 patterns would be the slowest thing the tool does.

Resolution order for a candidate:

1. collect candidate rules from the three buckets
2. first `Certain` rule whose markers are satisfied → match, stop
3. otherwise, if the candidate is a folder, try `innerMarkers` (touches the disk)
4. otherwise, fall back to the first `Uncertain` rule seen
5. otherwise, no match

## Case sensitivity

Windows matches case-insensitively, Linux case-sensitively, because that is what each
filesystem does. Write names in their real case. It is usually invisible, but it is the
reason Unity's `Build` and Node's `build` are different rules rather than one ambiguous one.

Where a name genuinely appears in several cases, list each one.

## Adding a rule

1. Add the entry to `rules/rules.json`, in the section it belongs to.
2. Add a case to **both** test suites. `linux/tests/test_rules.py` and
   `windows/tests/Rules.Tests.ps1` have parametrised lists that most rules fit into.
3. Run the Linux suite locally (`cd linux && python3 -m pytest tests/test_rules.py`); CI runs
   the Windows one.

Before adding anything, check it against the bar the tool sets for itself: **a build, an
install or the editor must recreate it without the user doing anything.** A cache qualifies.
A downloaded dependency qualifies. Anything holding a decision the user made does not — which
is why `.bundle`, `desktop.ini` and `.directory` are deliberately absent, and why backups
(`*.bak`, `*.orig`, `*~`) are never touched.

If it only qualifies some of the time, that is what `Uncertain` is for.

## What lives in code, not in the table

Two behaviours cannot be expressed as rules and are implemented in the scanner:

- **Skipped folders** — `.git`, `.hg`, `.svn`, and on Linux `lost+found` and `.Trash-*`. Never
  descended into, never listed.
- **Global tool caches** (Linux only) — any generated folder directly inside `$HOME` is
  downgraded to `Uncertain` with its own note, because `~/.gradle` is not project output even
  though it matches a project-output rule.
