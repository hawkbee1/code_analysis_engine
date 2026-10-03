// Analyzes the real flutter_scene submodule: no exception, sane counts.
// The numbers it prints are recorded in the session logs.
@Tags(['slow', 'skip_very_good_optimization'])
library;

import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_source_client/code_source_client.dart';
import 'package:test/test.dart';

void main() {
  test('analyzes the flutter_scene submodule', () async {
    late SourceSnapshot snapshot;
    await for (final event in CodeSourceClient().fetch(
      const LocalFolderSource('../flutter_scene'),
    )) {
      if (event is FetchDone) snapshot = event.snapshot;
      if (event is FetchFailed) fail('${event.failure}');
    }
    final watch = Stopwatch()..start();
    final last = await CodeAnalysisEngine()
        .analyze(snapshot, AnalysisRules.defaults())
        .last;
    if (last is AnalysisFailed) fail('${last.error}\n${last.stackTrace}');
    final graph = (last as AnalysisDone).graph;

    final byKind = <String, int>{};
    for (final node in graph.nodes.values) {
      byKind.update(node.kind.name, (n) => n + 1, ifAbsent: () => 1);
    }
    // The numbers are recorded in the session logs.
    // ignore: avoid_print
    print(
      'flutter_scene: ${watch.elapsedMilliseconds} ms, '
      '${graph.project.stats.toJson()}, $byKind, entry '
      '${graph.project.entryNodeId}',
    );
    expect(graph.project.stats.parseErrors, 0);
    expect(byKind['classDecl'], greaterThan(1000));
    expect(graph.project.entryNodeId, endsWith('lib/main.dart#main'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 60)));
  });
}
