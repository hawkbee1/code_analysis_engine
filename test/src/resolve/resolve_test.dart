import 'package:analyzer/dart/ast/ast.dart' hide Annotation, Declaration;
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:code_analysis_engine/src/resolve/declared_type_resolver.dart';
import 'package:code_analysis_engine/src/resolve/reference_resolver.dart';
import 'package:code_analysis_engine/src/resolve/resolvers.dart';
import 'package:code_graph/code_graph.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

class _NoLocals implements Scope {
  @override
  LocalVariable? lookup(String name) => null;
}

class _Rename implements GraphAnnotator {
  @override
  CodeGraph annotate(CodeGraph graph) => CodeGraph(
    project: graph.project,
    nodes: {
      for (final MapEntry(:key, :value) in graph.nodes.entries)
        key: CodeNode(
          id: value.id,
          kind: value.kind,
          name: value.name,
          parentId: value.parentId,
          annotations: const [
            Annotation(patternId: 'test', role: 'any', confidence: 1),
          ],
        ),
    },
    links: graph.links,
  );
}

MethodInvocation _firstInvocation(String source) {
  final file = ParsedFile.parse('lib/a.dart', source)!;
  late MethodInvocation found;
  file.unit.accept(_InvocationFinder((node) => found = node));
  return found;
}

class _InvocationFinder extends RecursiveAstVisitor<void> {
  new(this.onFound);

  final void Function(MethodInvocation) onFound;

  @override
  void visitMethodInvocation(MethodInvocation node) => onFound(node);
}

void main() {
  group(DeclaredTypeResolver, () {
    test('reports an unknown library as not found', () {
      const resolver = UriResolver({});
      final context = ResolverContext(
        symbols: SymbolTable.build(const [], resolver),
        nodeIdsByAst: const {},
        rules: AnalysisRules.defaults(),
      );

      final result = const DeclaredTypeResolver().resolve(
        ReferenceSite(
          kind: SiteKind.invocation,
          node: _firstInvocation('void f() { g(); }'),
          enclosingNodeId: 'f',
          libraryPath: 'lib/unknown.dart',
          scope: _NoLocals(),
        ),
        context,
      );

      expect(result, const Unresolved('not found'));
    });
  });

  group('resolverFor', () {
    test('gives the declared type resolver for parse only', () {
      expect(
        resolverFor(ResolutionMode.parseOnly),
        isA<DeclaredTypeResolver>(),
      );
    });

    test('refuses full resolution, not available yet', () {
      expect(
        () => resolverFor(ResolutionMode.fullResolution),
        throwsUnsupportedError,
      );
    });
  });

  group(ResolvedReference, () {
    test('compares by value', () {
      // Built at runtime: identical constants would skip the comparison.
      final id = ['a'].single;
      expect(
        ResolvedToNode(id, LinkResolution.exact),
        ResolvedToNode(id, LinkResolution.exact),
      );
      expect(ResolvedAmbiguous([id]), ResolvedAmbiguous([id]));
      expect(ResolvedExternal(id), ResolvedExternal(id));
      expect(Unresolved(id), Unresolved(id));
    });
  });

  group(CallSiteStats, () {
    test('totals the call sites and describes itself', () {
      const stats = CallSiteStats(
        exact: 1,
        byName: 2,
        ambiguous: 3,
        external: 4,
        unresolved: 5,
        getterLinks: 6,
        skippedTopLevel: 7,
      );

      expect(stats.total, 15);
      expect(stats.props, [1, 2, 3, 4, 5, 6, 7]);
      expect(stats.toString(), contains('skippedTopLevel: 7'));
    });
  });

  group('links', () {
    test('import links reach the SDK and skip unresolvable URIs', () async {
      final graph = await analyzeOrFail(
        snapshotOf({
          'lib/a.dart':
              "import 'dart:async';\n"
              "import 'http://example.com/x.dart';\nclass A {}",
        }),
        AnalysisRules.defaults()
            .copyWith(RuleIds.linksImports, true)
            .copyWith(RuleIds.dartSdk, true),
      );

      expect(linkTuples(graph), [
        ['lib/a.dart#A', 'pkg:dart', 'import', 'external', '1'],
      ]);
    });

    test('implements through an unknown prefix links nothing', () async {
      final graph = await analyzeOrFail(
        snapshotOf({'lib/a.dart': 'class A implements p.Missing {}'}),
        AnalysisRules.defaults(),
      );

      expect(graph.links, isEmpty);
    });
  });

  group('annotators', () {
    test('run on the finished graph', () async {
      final last = await CodeAnalysisEngine(annotators: [_Rename()])
          .analyze(
            snapshotOf({'lib/a.dart': 'class A {}'}),
            AnalysisRules.defaults(),
          )
          .last;

      final node = (last as AnalysisDone).graph.nodes['lib/a.dart#A']!;
      expect(node.annotations.single.patternId, 'test');
      expect(last.callSites, const CallSiteStats());
    });
  });

  group('calls', () {
    test('are not resolved when the calls rule is off', () async {
      final last = await CodeAnalysisEngine()
          .analyze(
            snapshotOf({'lib/a.dart': 'void f() { g(); }\nvoid g() {}'}),
            AnalysisRules.defaults().copyWith(RuleIds.linksCalls, false),
          )
          .last;

      expect((last as AnalysisDone).graph.links, isEmpty);
      expect(last.callSites.total, 0);
    });
  });
}
