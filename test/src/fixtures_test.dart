import 'dart:io';

import 'package:test/test.dart';

import '../helpers/fixtures.dart';

void main() {
  final names =
      Directory('test/fixtures')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList()
        ..sort();

  group('fixture', () {
    test('folders exist', () => expect(names, isNotEmpty));

    for (final name in names) {
      final fixture = Fixture.load(name);
      for (final expectation in fixture.expectations) {
        test(
          '$name (${expectation.name}) produces exactly the expected graph',
          () async {
            final graph = await analyzeOrFail(
              fixture.snapshot(),
              expectation.rules,
            );

            expect(nodeTriples(graph), expectation.nodes);
            expect(graph.project.entryNodeId, expectation.entry);
            if (expectation.links case final links?) {
              expect(linkTuples(graph), links);
            }
            for (final MapEntry(key: id, value: loc)
                in expectation.loc.entries) {
              expect(graph.nodes[id]!.loc, loc, reason: 'loc of $id');
            }
            final stats = graph.project.stats.toJson();
            for (final MapEntry(:key, :value) in expectation.stats.entries) {
              expect(stats[key], value, reason: 'stats.$key');
            }
          },
        );
      }
    }
  });
}
