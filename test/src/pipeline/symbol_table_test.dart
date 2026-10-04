import 'package:code_analysis_engine/src/pipeline/file_collector.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:test/test.dart';

SymbolTable _table(Map<String, String> sources) {
  const resolver = UriResolver({'app': ProjectPackage('app', '')});
  return SymbolTable.build(
    groupLibraries([
      for (final MapEntry(:key, :value) in sources.entries)
        ParsedFile.parse(key, value)!,
    ], resolver),
    resolver,
  );
}

String _describe(SymbolLookup lookup) => switch (lookup) {
  ProjectSymbol(:final declaration) => 'project ${declaration.name}',
  ExternalSymbol(:final packageName) => 'external $packageName',
  SymbolNotFound() => 'not found',
};

void main() {
  group(SymbolTable, () {
    group('exportNamespace', () {
      test(
        'exports public declarations and follows exports with combinators',
        () {
          final table = _table({
            'lib/app.dart':
                "export 'a.dart' show A; export 'b.dart' hide B2; "
                "export 'package:http/http.dart'; class _P {} class Own {}",
            'lib/a.dart': 'class A {} class A2 {}',
            'lib/b.dart': 'class B1 {} class B2 {}',
          });

          expect(table.exportNamespace('lib/app.dart').keys, {
            'Own',
            'A',
            'B1',
          });
          expect(table.exportNamespace('lib/unknown.dart'), isEmpty);
        },
      );

      test('survives export cycles', () {
        final table = _table({
          'lib/a.dart': "export 'b.dart'; class A {}",
          'lib/b.dart': "export 'a.dart'; class B {}",
        });

        expect(table.exportNamespace('lib/a.dart').keys, {'A', 'B'});
        expect(table.exportNamespace('lib/b.dart').keys, containsAll(['B']));
      });
    });

    group('lookup', () {
      test('finds own declarations, private ones included', () {
        final table = _table({'lib/a.dart': 'class _Secret {}'});

        expect(
          _describe(table.lookup('lib/a.dart', '_Secret')),
          'project _Secret',
        );
      });

      test('finds imported project types, unprefixed or prefixed', () {
        final table = _table({
          'lib/a.dart': "import 'b.dart'; import 'c.dart' as c;",
          'lib/b.dart': 'class B {}',
          'lib/c.dart': 'class C {}',
        });

        expect(_describe(table.lookup('lib/a.dart', 'B')), 'project B');
        expect(
          _describe(table.lookup('lib/a.dart', 'C', prefix: 'c')),
          'project C',
        );
        expect(
          _describe(table.lookup('lib/a.dart', 'X', prefix: 'nope')),
          'not found',
        );
        expect(_describe(table.lookup('lib/z.dart', 'B')), 'not found');
      });

      test('guesses the package of external types', () {
        final table = _table({
          'lib/one.dart': "import 'package:http/http.dart';",
          'lib/two.dart':
              "import 'package:a/a.dart'; "
              "import 'package:b/b.dart' show Shown; "
              "import 'package:c/c.dart' hide Hidden; import 'dart:async';",
          'lib/none.dart': '',
        });

        String guess(String library, String name) =>
            _describe(table.lookup(library, name));

        expect(guess('lib/one.dart', 'Client'), 'external http');
        expect(guess('lib/two.dart', 'Shown'), 'external b');
        expect(guess('lib/two.dart', 'Thing'), 'external unknown');
        expect(guess('lib/two.dart', 'StatelessWidget'), 'external flutter');
        expect(guess('lib/none.dart', 'Thing'), 'external dart');
      });
    });

    test('reads imports with prefix and combinators', () {
      final table = _table({
        'lib/a.dart': "import 'package:x/x.dart' as x show A, B hide C;",
      });
      final import = table.libraries['lib/a.dart']!.imports.single;

      expect(import.target, const ExternalLibrary('x'));
      expect(import.prefix, 'x');
      expect(import.allows('A'), isTrue);
      expect(import.allows('C'), isFalse);
      expect(import.allows('D'), isFalse);
    });

    test('records members with their kinds and declared types', () {
      final table = _table({
        'lib/a.dart': '''
class A {
  A();
  static int count = 0;
  final String name = '';
  int get size => 1;
  set size(int v) {}
  void run() {}
}
int topVariable = 1;
typedef Fn = void Function();
''',
      });
      final declarations = table.libraries['lib/a.dart']!.declarations;
      final members = declarations['A']!.members;

      expect(members.map((m) => '${m.kind.name} ${m.name}'), [
        'constructor new',
        'field count',
        'field name',
        'getter size',
        'setter size',
        'method run',
      ]);
      expect(members[1].isStatic, isTrue);
      expect(members[2].type!.toSource(), 'String');
      expect(declarations['topVariable']!.kind, DeclKind.variable);
      expect(declarations['topVariable']!.type!.toSource(), 'int');
      expect(declarations['Fn']!.kind, DeclKind.typeAlias);
      expect(declarations['A']!.isPrivate, isFalse);
    });

    test('compares lookup results by value', () {
      // Built at runtime: identical constants would skip the comparison.
      final name = ['a'].single;
      expect(ExternalSymbol(name), ExternalSymbol(name));
      expect(const SymbolNotFound().props, isEmpty);
      final declaration = _table({'lib/a.dart': 'class A {}'})
          .libraries['lib/a.dart']!
          .declarations['A']!;
      expect(ProjectSymbol(declaration), ProjectSymbol(declaration));
    });
  });
}
