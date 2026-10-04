// Runs bin/analyze.dart as a process (bin/ is outside coverage).
@Tags(['skip_very_good_optimization'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _cli(List<String> arguments) =>
    Process.run('dart', ['run', 'bin/analyze.dart', ...arguments]);

void main() {
  group('analyze CLI', () {
    late Directory project;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('cli_test_');
      addTearDown(() => project.delete(recursive: true));
      File('${project.path}/pubspec.yaml').writeAsStringSync('name: app\n');
      File('${project.path}/lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'class A { void f() {} }\nvoid main() { A().f(); }',
        );
    });

    test('prints a summary, stats, and writes the graph', () async {
      final out = '${project.path}/graph.json';
      final result = await _cli([project.path, '--stats', '--out', out]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stdout,
        contains('1 files (0 with syntax errors), 3 nodes'),
      );
      expect(result.stdout, contains('call sites: CallSiteStats(exact: 2'));
      expect(result.stdout, contains('stage durations: listing'));
      expect(result.stdout, contains('peak memory (RSS)'));
      final graph = jsonDecode(File(out).readAsStringSync()) as Map;
      expect((graph['nodes'] as List).length, 3);
    });

    test('reads rules and warns about invalid values', () async {
      final rules = File('${project.path}/rules.json')
        ..writeAsStringSync('{"links.calls": false, "nodes.private": "no"}');

      final result = await _cli([project.path, '--rules', rules.path]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('0 links'));
      expect(result.stderr, contains('Invalid value for nodes.private'));
    });

    test('fails for a missing folder or bad arguments', () async {
      final missing = await _cli(['${project.path}/nope']);
      final noFolder = await _cli([]);
      final badOption = await _cli(['--bogus']);
      final help = await _cli(['--help']);

      expect(missing.exitCode, 1);
      expect(missing.stderr, contains('Folder not found'));
      expect(noFolder.exitCode, 64);
      expect(badOption.exitCode, 1);
      expect(help.exitCode, 0);
      expect(help.stdout, contains('Usage'));
    });
  });
}
