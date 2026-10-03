import 'package:code_analysis_engine/src/runner/engine_runner.dart';

/// The web has no isolates: the engine runs inline and yields regularly.
EngineRunner defaultEngineRunner() => InlineEngineRunner();
