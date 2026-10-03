import 'dart:async';
import 'dart:isolate';

import 'package:code_analysis_engine/src/engine.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_analysis_engine/src/runner/engine_runner.dart';
import 'package:code_source_client/code_source_client.dart';

/// Native platforms run the engine in an isolate, off the UI thread.
EngineRunner defaultEngineRunner() => const IsolateEngineRunner();

/// Runs each analysis in a new isolate of the same isolate group, so the
/// snapshot and the resulting graph are passed without serialization.
///
/// Cancelling the token (or the subscription) sends a cancel message; the
/// engine yields to the event loop after each progress event, so it stops
/// within a few files.
class IsolateEngineRunner implements EngineRunner {
  /// Creates the runner.
  const new();

  @override
  Stream<AnalysisEvent> run(
    SourceSnapshot snapshot,
    AnalysisRules rules, {
    CancelToken? cancel,
  }) {
    final token = cancel ?? CancelToken();
    final events = ReceivePort();
    late final StreamController<AnalysisEvent> controller;
    SendPort? control;
    Timer? watch;

    void stop() {
      watch?.cancel();
      events.close();
    }

    controller = StreamController<AnalysisEvent>(
      onListen: () async {
        // The token belongs to the caller: watch it and forward a cancel.
        watch = Timer.periodic(const Duration(milliseconds: 20), (_) {
          if (token.isCancelled) control?.send(_cancelMessage);
        });
        events.listen((message) {
          switch (message) {
            case SendPort():
              control = message;
              if (token.isCancelled) message.send(_cancelMessage);
            case AnalysisEvent():
              controller.add(message);
              if (message is AnalysisDone || message is AnalysisFailed) {
                stop();
                unawaited(controller.close());
              }
          }
        });
        await Isolate.spawn(_analyzeInIsolate, (
          events.sendPort,
          snapshot,
          rules.toJson(),
        ), errorsAreFatal: false);
      },
      onCancel: () {
        token.cancel();
        control?.send(_cancelMessage);
        stop();
      },
    );
    return controller.stream;
  }

  static const _cancelMessage = 'cancel';

  static Future<void> _analyzeInIsolate(
    (SendPort, SourceSnapshot, Map<String, Object?>) message,
  ) async {
    final (events, snapshot, rulesJson) = message;
    final token = CancelToken();
    final control = ReceivePort()..listen((_) => token.cancel());
    events.send(control.sendPort);
    await CodeAnalysisEngine(yieldToEventLoop: true)
        .analyze(snapshot, AnalysisRules.fromJson(rulesJson), cancel: token)
        .forEach(events.send);
    control.close();
  }
}
