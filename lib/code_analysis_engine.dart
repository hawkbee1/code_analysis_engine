/// The dart_code_3D analysis engine: turns Dart source into a code graph,
/// driven by configurable rules.
library;

export 'src/engine.dart';
export 'src/resolve/link_builder.dart' show CallSiteStats, GraphAnnotator;
export 'src/rules/analysis_rules.dart';
export 'src/rules/rule_catalog.dart';
export 'src/rules/rule_parameter.dart';
export 'src/runner/engine_runner.dart';
export 'src/runner/runner.dart' show defaultEngineRunner;
