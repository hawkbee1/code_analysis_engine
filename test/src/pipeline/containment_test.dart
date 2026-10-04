import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_analysis_engine/src/pipeline/containment.dart';
import 'package:code_graph/code_graph.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

void main() {
  group('buildContainment', () {
    test('gives duplicate members unique ids', () async {
      final graph = await analyzeOrFail(
        snapshotOf({
          'lib/a.dart': 'class A { void m() {} void m() {} void m() {} }',
        }),
        AnalysisRules.defaults(),
      );

      expect(graph.nodes.keys, [
        'lib/a.dart#A',
        'lib/a.dart#A.m',
        'lib/a.dart#A.m#2',
        'lib/a.dart#A.m#3',
      ]);
    });

    test('keeps the first of duplicate top-level declarations', () async {
      final graph = await analyzeOrFail(
        snapshotOf({'lib/a.dart': 'class A {}\nclass A {}'}),
        AnalysisRules.defaults(),
      );

      expect(graph.nodes.keys, ['lib/a.dart#A']);
    });

    test('adds the dart package when the SDK rule is on', () async {
      final graph = await analyzeOrFail(
        snapshotOf({'lib/a.dart': "import 'dart:async';\nclass A {}"}),
        AnalysisRules.defaults().copyWith(RuleIds.dartSdk, true),
      );

      expect(graph.nodes.keys, contains('pkg:dart'));
    });

    test('nests only in project classes, not mixins', () async {
      final graph = await analyzeOrFail(
        snapshotOf({'lib/a.dart': 'mixin M {}\nclass A extends M {}'}),
        AnalysisRules.defaults(),
      );

      expect(graph.nodes['lib/a.dart#A']!.parentId, isNull);
    });

    test('drops external packages when the rule is off', () async {
      final graph = await analyzeOrFail(
        snapshotOf({'lib/a.dart': "import 'package:http/http.dart';"}),
        AnalysisRules.defaults().copyWith(RuleIds.externalPackages, false),
      );

      expect(graph.nodes, isEmpty);
    });
  });

  group('findEntryNode', () {
    CodeNode main(String path) => CodeNode(
      id: '$path#main',
      kind: CodeNodeKind.function,
      name: 'main',
      location: SourceLocation(filePath: path, startLine: 1, endLine: 1),
    );

    String? entry(
      List<CodeNode> nodes, {
      String entryPoint = 'lib/main.dart',
    }) => findEntryNode({for (final n in nodes) n.id: n}, entryPoint);

    test('prefers the entry file, then the same file in a sub-package', () {
      expect(
        entry([main('lib/main.dart'), main('a/lib/main.dart')]),
        'lib/main.dart#main',
      );
      expect(
        entry([main('apps/long/lib/main.dart'), main('apps/x/lib/main.dart')]),
        'apps/x/lib/main.dart#main',
      );
    });

    test('falls back to flavors, then any main under lib/', () {
      expect(
        entry([main('lib/main_prod.dart'), main('lib/other.dart')]),
        'lib/main_prod.dart#main',
      );
      expect(
        entry([main('bin/x.dart'), main('pkg/lib/run.dart')]),
        'pkg/lib/run.dart#main',
      );
    });

    test('falls back to the largest declaration, or nothing', () {
      expect(entry(const []), isNull);
      expect(
        entry(const [
          CodeNode(id: 'pkg:x', kind: CodeNodeKind.externalPackage, name: 'x'),
          CodeNode(id: 'a', kind: CodeNodeKind.classDecl, name: 'A', loc: 3),
          CodeNode(id: 'b', kind: CodeNodeKind.classDecl, name: 'B', loc: 9),
          CodeNode(
            id: 'm',
            kind: CodeNodeKind.method,
            name: 'm',
            parentId: 'a',
            loc: 50,
          ),
        ]),
        'b',
      );
    });
  });

  group('Containment', () {
    test('records external superclasses when ghost parents are off', () async {
      final graph = await analyzeOrFail(
        snapshotOf({
          'lib/a.dart':
              "import 'package:bloc/bloc.dart';\n"
              'class C extends Cubit<int> { C() : super(0); }',
        }),
        AnalysisRules.defaults().copyWith(RuleIds.ghostParents, false),
      );

      expect(graph.nodes['lib/a.dart#C']!.parentId, isNull);
      expect(graph.nodes.keys, isNot(contains('ghost:bloc:Cubit')));
    });
  });
}
