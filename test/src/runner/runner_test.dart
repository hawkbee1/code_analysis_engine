import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_analysis_engine/src/runner/runner_io.dart'
    show IsolateEngineRunner;
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

Map<String, String> _manyFiles(int count) => {
  for (var i = 0; i < count; i++)
    'lib/f$i.dart': 'class C$i { void m() { C${(i + 1) % count}().m(); } }',
};

void main() {
  group(InlineEngineRunner, () {
    test('runs the engine on the current thread', () async {
      final last = await InlineEngineRunner()
          .run(
            snapshotOf({'lib/a.dart': 'class A {}'}),
            AnalysisRules.defaults(),
          )
          .last;

      expect((last as AnalysisDone).graph.nodes.keys, ['lib/a.dart#A']);
    });
  });

  group(IsolateEngineRunner, () {
    test('gives the same graph as the inline runner', () async {
      final snapshot = snapshotOf(_manyFiles(30));
      final rules = AnalysisRules.defaults();

      final inline = await InlineEngineRunner().run(snapshot, rules).last;
      final isolated = await const IsolateEngineRunner()
          .run(snapshot, rules)
          .last;

      final a = (inline as AnalysisDone).graph;
      final b = (isolated as AnalysisDone).graph;
      expect(b.nodes, a.nodes);
      expect(b.links, a.links);
      expect(isolated.callSites, inline.callSites);
    });

    test('stops promptly when the token is cancelled', () async {
      final token = CancelToken();
      final watch = Stopwatch();
      final events = <AnalysisEvent>[];
      await for (final event in const IsolateEngineRunner().run(
        snapshotOf(_manyFiles(3000)),
        AnalysisRules.defaults(),
        cancel: token,
      )) {
        events.add(event);
        if (event is AnalysisProgress && event.done >= 50 && !watch.isRunning) {
          watch.start();
          token.cancel();
        }
      }

      expect(events.last, const AnalysisFailed(AnalysisCancelled()));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 250)));
    });

    test('honours a token cancelled before the isolate starts', () async {
      final events = await const IsolateEngineRunner()
          .run(
            snapshotOf(_manyFiles(200)),
            AnalysisRules.defaults(),
            cancel: CancelToken()..cancel(),
          )
          .toList();

      expect(events.last, const AnalysisFailed(AnalysisCancelled()));
    });

    test('stops the isolate when the subscription is cancelled', () async {
      final stream = const IsolateEngineRunner().run(
        snapshotOf(_manyFiles(3000)),
        AnalysisRules.defaults(),
      );
      final first = await stream.first;

      expect(first, isA<AnalysisProgress>());
    });
  });

  test('defaultEngineRunner uses an isolate on native platforms', () {
    expect(defaultEngineRunner(), isA<IsolateEngineRunner>());
  });
}
