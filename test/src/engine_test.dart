import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_graph/code_graph.dart';
import 'package:code_source_client/code_source_client.dart';
import 'package:test/test.dart';

import '../helpers/fixtures.dart';

class _FailingSnapshot implements SourceSnapshot {
  @override
  SourceDescriptor get descriptor => const ZipDescriptor(fileName: 'a.zip');

  @override
  List<String> get paths => const ['lib/a.dart'];

  @override
  Future<String> readAsString(String path) async => throw StateError('disk');

  @override
  Future<void> dispose() async {}
}

void main() {
  group(CodeAnalysisEngine, () {
    final rules = AnalysisRules.defaults();

    test('emits progress through every stage, then the graph', () async {
      final events = await CodeAnalysisEngine()
          .analyze(snapshotOf({'lib/a.dart': 'class A {}'}), rules)
          .toList();

      expect(events.whereType<AnalysisProgress>().map((e) => e.stage), [
        AnalysisStage.collecting,
        AnalysisStage.parsing,
        AnalysisStage.declarations,
        AnalysisStage.containment,
      ]);
      expect(events.last, isA<AnalysisDone>());
    });

    test('reports parsing progress every 25 files', () async {
      final events = await CodeAnalysisEngine()
          .analyze(
            snapshotOf({for (var i = 0; i < 60; i++) 'lib/f$i.dart': ''}),
            rules,
          )
          .toList();
      final parsing = events
          .whereType<AnalysisProgress>()
          .where((e) => e.stage == AnalysisStage.parsing)
          .toList();

      expect(parsing.map((e) => e.done), [0, 25, 50]);
      expect(parsing.first.total, 60);
      expect(parsing.first.currentPath, 'lib/f0.dart');
    });

    test('writes the project metadata', () async {
      final graph = await analyzeOrFail(
        snapshotOf({'lib/main.dart': 'void main() {}'}),
        rules.copyWith(RuleIds.linksImports, true),
      );
      final project = graph.project;

      expect(project.generator, CodeAnalysisEngine.defaultGenerator);
      expect(project.source, const LocalFolderDescriptor(name: 'test'));
      expect(project.createdAt, DateTime.utc(2026, 10, 3));
      expect(project.rules[RuleIds.linksImports], isTrue);
      expect(project.entryNodeId, 'lib/main.dart#main');
      expect(project.stats.files, 1);
      expect(project.stats.nodes, 1);
    });

    test('stops when cancelled before it starts', () async {
      final token = CancelToken()..cancel();

      final events = await CodeAnalysisEngine()
          .analyze(snapshotOf({'lib/a.dart': ''}), rules, cancel: token)
          .toList();

      expect(token.isCancelled, isTrue);
      expect(events.last, const AnalysisFailed(AnalysisCancelled()));
    });

    test('stops when cancelled while parsing', () async {
      final token = CancelToken();
      final events = <AnalysisEvent>[];
      await for (final event in CodeAnalysisEngine().analyze(
        snapshotOf({for (var i = 0; i < 60; i++) 'lib/f$i.dart': ''}),
        rules,
        cancel: token,
      )) {
        events.add(event);
        if (event is AnalysisProgress && event.done == 25) token.cancel();
      }

      expect(events.last, const AnalysisFailed(AnalysisCancelled()));
      expect(events.whereType<AnalysisDone>(), isEmpty);
    });

    test('stops after parsing when cancelled on the last file', () async {
      final token = CancelToken();
      final events = <AnalysisEvent>[];
      await for (final event in CodeAnalysisEngine().analyze(
        snapshotOf({'lib/a.dart': ''}),
        rules,
        cancel: token,
      )) {
        events.add(event);
        if (event is AnalysisProgress && event.stage == AnalysisStage.parsing) {
          token.cancel();
        }
      }

      expect(events.last, const AnalysisFailed(AnalysisCancelled()));
    });

    test('reports a bug as a failure with its stack trace', () async {
      final events = await CodeAnalysisEngine()
          .analyze(_FailingSnapshot(), rules)
          .toList();
      final failed = events.last as AnalysisFailed;

      expect(failed.error, isA<StateError>());
      expect(failed.stackTrace, isNotNull);
    });

    test('compares events by value', () {
      // Built at runtime: identical constants would skip the comparison.
      final done = [1].single;
      expect(
        AnalysisProgress(AnalysisStage.parsing, done: done, total: 2),
        AnalysisProgress(AnalysisStage.parsing, done: done, total: 2),
      );
      expect(AnalysisFailed(StateError('x')).props, hasLength(1));
      final graph = CodeGraph(
        project: ProjectInfo(
          generator: 'g',
          source: const ZipDescriptor(fileName: 'a.zip'),
          createdAt: DateTime.utc(2026),
        ),
        nodes: const {},
      );
      expect(AnalysisDone(graph), AnalysisDone(graph));
      expect(const AnalysisCancelled().props, isEmpty);
    });
  });
}
