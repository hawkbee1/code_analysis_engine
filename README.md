# code_analysis_engine

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

The analysis engine of [dart_code_3D](https://github.com/hawkbee1/dart_code_3d): it
turns a `SourceSnapshot` (from `code_source_client`) into a `CodeGraph` (from
`code_graph`), driven by configurable **rules**. Pure Dart: it only uses the
analyzer's **parser** (`parseString`), so it also runs on the web (checked with a JS build).

## Part of hawkbee

This repository is a git submodule of the
[hawkbee](https://github.com/hawkbee1/hawkbee) monorepo and **only builds inside it**:

```sh
git clone --recurse-submodules https://github.com/hawkbee1/hawkbee.git
cd hawkbee && flutter pub get
```

Design: hawkbee's [docs/dart_code_3d/architecture.md](https://github.com/hawkbee1/hawkbee/blob/main/docs/dart_code_3d/architecture.md) §5.

## Usage

```dart
final engine = CodeAnalysisEngine();
final rules = AnalysisRules.defaults().copyWith(RuleIds.linksImports, true);
await for (final event in engine.analyze(snapshot, rules, cancel: token)) {
  switch (event) {
    case AnalysisProgress(:final stage, :final done, :final total):
      print('$stage $done/$total');
    case AnalysisDone(:final graph):
      print(graph.project.stats.toJson());
    case AnalysisFailed(:final error):
      print(error); // AnalysisCancelled, or a bug with its stack trace
  }
}
```

## Pipeline (architecture §5.1)

1. **Collect** (`FileCollector`): file rules; every `pubspec.yaml` is a project package
   (a monorepo is one project).
2. **Parse** (`ParsedFile`): files with syntax errors are skipped and counted in
   `stats.parseErrors`. `part` files join their library, by URI or by library name.
3. **Declarations** (`SymbolTable`): top-level declarations and members with declared
   types; imports/exports with prefixes and `show`/`hide`; **export namespaces followed
   transitively** (barrels), cycle-safe. `lookupType` guesses the package of external
   types (a short list of well-known types, else the only candidate import).
4. **Containment**: members inside their type; `extends` a project class → nested;
   `extends` an external class → inside a **ghost parent** (`ghost:<pkg>:<Class>`);
   external packages → `pkg:<name>`. Lines of code exclude blank and comment lines, and a
   type's own count excludes its member spheres. Entry node: `main()` of
   `entry.point`, then a sub-package's, then `lib/main_development.dart`, then
   `lib/main_*.dart`, then any `main()` under `lib/`, then the largest top-level declaration.
5. **Links**: session 06 (calls through a `ReferenceResolver` strategy).

## Rules

`RuleCatalog.all` defines every rule (id, title, description, group, type, default);
`AnalysisRules` holds the values (immutable, JSON round trip, typed getters). The
settings screen renders the catalog generically, so a new rule needs no UI code.

## Tests

```sh
very_good test --coverage
```

Fixtures are small projects written as one text file (`test/fixtures/<name>/source.txt`,
sections `=== <path>`), so the package's own analysis never sees their (sometimes
deliberately broken) code. Each `expected*.json` holds the rules and the **exact** expected
nodes, parents, lines of code and entry node.
`test/smoke/` analyzes the real flutter_scene submodule (tag `slow`): 622 files and 11,050
nodes in about 1.6 s.

[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
