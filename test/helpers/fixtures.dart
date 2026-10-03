import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_graph/code_graph.dart';
import 'package:code_source_client/code_source_client.dart';

/// One expectation file of a fixture: rules to use and the exact result.
class FixtureExpectation {
  /// Reads `expected*.json`.
  new fromJson(this.name, Map<String, Object?> json)
    : rules = AnalysisRules.fromJson(
        (json['rules'] as Map<String, Object?>?) ?? const {},
      ),
      nodes = [
        for (final n in json['nodes']! as List<Object?>)
          (n! as List<Object?>).cast<String?>(),
      ],
      loc = ((json['loc'] as Map<String, Object?>?) ?? const {}).cast(),
      links = (json['links'] as List<Object?>?)
          ?.map((l) => (l! as List<Object?>).map((v) => '$v').toList())
          .toList(),
      entry = json['entry'] as String?,
      stats = ((json['stats'] as Map<String, Object?>?) ?? const {}).cast();

  /// File name, for test names.
  final String name;

  /// Rules: defaults overridden by the file's `rules`.
  final AnalysisRules rules;

  /// Every node in order, as `[id, kind, parentId]`.
  final List<List<String?>> nodes;

  /// Every link in order as `[from, to, kind, resolution, count]`, when the
  /// file lists links (checked exactly).
  final List<List<String>>? links;

  /// Expected lines of code of some nodes.
  final Map<String, int> loc;

  /// Expected entry node id.
  final String? entry;

  /// Expected stats counters (subset).
  final Map<String, int> stats;
}

/// A small project written as one `source.txt` (sections starting with
/// `=== <path>`) plus one or more `expected*.json` files.
///
/// Fixtures are text, not `.dart` files, so the package's own analysis and
/// formatting never see their (sometimes deliberately broken) code.
class Fixture {
  /// Loads `test/fixtures/<name>`.
  factory load(String name) {
    final dir = Directory('test/fixtures/$name');
    final files = <String, Uint8List>{};
    String? current;
    final buffer = StringBuffer();
    void flush() {
      if (current != null) {
        files[current] = Uint8List.fromList(utf8.encode(buffer.toString()));
      }
      buffer.clear();
    }

    for (final line in File('${dir.path}/source.txt').readAsLinesSync()) {
      if (line.startsWith('=== ')) {
        flush();
        current = line.substring(4).trim();
      } else {
        buffer.writeln(line);
      }
    }
    flush();
    final expectations = [
      for (final file
          in dir.listSync().whereType<File>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        if (file.uri.pathSegments.last.startsWith('expected'))
          FixtureExpectation.fromJson(
            file.uri.pathSegments.last,
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
          ),
    ];
    return Fixture._(name, files, expectations);
  }

  new _(this.name, this.files, this.expectations);

  /// Folder name.
  final String name;

  /// Path → content.
  final Map<String, Uint8List> files;

  /// The expectation files.
  final List<FixtureExpectation> expectations;

  /// A fresh in-memory snapshot of the files.
  SourceSnapshot snapshot() => MemorySnapshot(
    descriptor: LocalFolderDescriptor(name: name),
    files: files,
  );
}

/// Runs the engine and returns its graph, failing on [AnalysisFailed].
Future<CodeGraph> analyzeOrFail(
  SourceSnapshot snapshot,
  AnalysisRules rules,
) async {
  final events = await CodeAnalysisEngine(
    clock: () => DateTime.utc(2026, 10, 3),
  ).analyze(snapshot, rules).toList();
  final last = events.last;
  if (last is AnalysisFailed) {
    throw StateError('analysis failed: ${last.error}\n${last.stackTrace}');
  }
  return (last as AnalysisDone).graph;
}

/// The graph's links as `[from, to, kind, resolution, count]`.
List<List<String>> linkTuples(CodeGraph graph) => [
  for (final l in graph.links)
    [l.fromId, l.toId, l.kind.name, l.resolution.name, '${l.count}'],
];

/// The graph's nodes as `[id, kind, parentId]`, the format of fixtures.
List<List<String?>> nodeTriples(CodeGraph graph) => [
  for (final n in graph.nodes.values) [n.id, n.kind.name, n.parentId],
];

/// An in-memory snapshot of [files] (path → text).
SourceSnapshot snapshotOf(Map<String, String> files) => MemorySnapshot(
  descriptor: const LocalFolderDescriptor(name: 'test'),
  files: {
    for (final MapEntry(:key, :value) in files.entries)
      key: Uint8List.fromList(utf8.encode(value)),
  },
);
