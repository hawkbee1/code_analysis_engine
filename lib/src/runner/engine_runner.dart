import 'package:code_analysis_engine/src/engine.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_source_client/code_source_client.dart';

/// Runs an analysis somewhere: in an isolate (native platforms) or inline,
/// yielding to the event loop between batches (web, where there are no
/// isolates). Get the platform's with `defaultEngineRunner()`.
abstract interface class EngineRunner {
  /// Analyzes [snapshot]; same events as [CodeAnalysisEngine.analyze].
  Stream<AnalysisEvent> run(
    SourceSnapshot snapshot,
    AnalysisRules rules, {
    CancelToken? cancel,
  });
}

/// Runs the engine on the current thread, letting the event loop run after
/// each progress event so the UI stays responsive.
class InlineEngineRunner implements EngineRunner {
  /// Creates the runner; [engine] defaults to one that yields to the event
  /// loop.
  new({CodeAnalysisEngine? engine})
    : engine = engine ?? CodeAnalysisEngine(yieldToEventLoop: true);

  /// The engine it runs.
  final CodeAnalysisEngine engine;

  @override
  Stream<AnalysisEvent> run(
    SourceSnapshot snapshot,
    AnalysisRules rules, {
    CancelToken? cancel,
  }) => engine.analyze(snapshot, rules, cancel: cancel);
}
