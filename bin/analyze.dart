// Developer CLI: analyzes a folder with the engine, for agents and the
// owner (the app never uses it).
//
//   dart run code_analysis_engine:analyze <folder> [--rules rules.json]
//       [--out graph.json] [--stats]

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_source_client/code_source_client.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('rules', help: 'JSON file of rule values (rule id → value).')
    ..addOption('out', help: 'Write the code graph as JSON (debug format).')
    ..addFlag('stats', help: 'Print counters, stage durations and memory.')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (e) {
    _fail('${e.message}\n${parser.usage}');
  }
  if (options.flag('help') || options.rest.length != 1) {
    stdout.writeln(
      'Usage: dart run code_analysis_engine:analyze <folder> [options]\n'
      '${parser.usage}',
    );
    exit(options.flag('help') ? 0 : 64);
  }

  var rules = AnalysisRules.defaults();
  final rulesPath = options.option('rules');
  if (rulesPath != null) {
    final warnings = <String>[];
    rules = AnalysisRules.fromJson(
      jsonDecode(File(rulesPath).readAsStringSync()) as Map<String, Object?>,
      warnings: warnings,
    );
    warnings.forEach(stderr.writeln);
  }

  final watch = Stopwatch()..start();
  SourceSnapshot? snapshot;
  await for (final event in CodeSourceClient().fetch(
    LocalFolderSource(options.rest.single),
  )) {
    if (event is FetchDone) snapshot = event.snapshot;
    if (event is FetchFailed) _fail(event.failure.message);
  }
  final listedMs = watch.elapsedMilliseconds;

  final stageStarts = <AnalysisStage, int>{};
  late AnalysisDone done;
  await for (final event in CodeAnalysisEngine().analyze(snapshot!, rules)) {
    switch (event) {
      case AnalysisProgress(:final stage):
        stageStarts.putIfAbsent(stage, () => watch.elapsedMilliseconds);
      case AnalysisDone():
        done = event;
      case AnalysisFailed(:final error, :final stackTrace):
        _fail('$error\n${stackTrace ?? ''}');
    }
  }
  final totalMs = watch.elapsedMilliseconds;
  final graph = done.graph;

  final out = options.option('out');
  if (out != null) {
    File(out).writeAsStringSync(jsonEncode(graph.toJson()));
    stdout.writeln('Wrote $out');
  }

  final stats = graph.project.stats;
  stdout.writeln(
    '${stats.files} files (${stats.parseErrors} with syntax errors), '
    '${stats.nodes} nodes, ${stats.links} links in ${totalMs - listedMs} ms; '
    'entry ${graph.project.entryNodeId}',
  );
  if (!options.flag('stats')) return;

  Map<String, int> count(Iterable<String> keys) {
    final counts = <String, int>{};
    for (final key in keys) {
      counts.update(key, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  stdout
    ..writeln(
      'nodes by kind: ${count(graph.nodes.values.map((n) => n.kind.name))}',
    )
    ..writeln(
      'links by kind/resolution: '
      '${count(graph.links.map((l) => '${l.kind.name}/${l.resolution.name}'))}',
    )
    ..writeln('call sites: ${done.callSites}');
  final stages = stageStarts.entries.toList();
  final durations = ['listing ${listedMs}ms'];
  for (final (i, MapEntry(key: stage, value: start)) in stages.indexed) {
    final end = i + 1 < stages.length ? stages[i + 1].value : totalMs;
    durations.add('${stage.name} ${end - start}ms');
  }
  stdout
    ..writeln('stage durations: ${durations.join(', ')}')
    ..writeln(
      'peak memory (RSS): ${(ProcessInfo.maxRss / (1024 * 1024)).round()} MB',
    );
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
