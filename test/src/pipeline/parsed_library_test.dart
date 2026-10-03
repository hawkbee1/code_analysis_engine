import 'package:code_analysis_engine/src/pipeline/file_collector.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:test/test.dart';

void main() {
  group(ParsedFile, () {
    test('returns null for a file with syntax errors', () {
      expect(ParsedFile.parse('lib/a.dart', 'class {'), isNull);
    });

    test('converts offsets to lines', () {
      final file = ParsedFile.parse('lib/a.dart', 'class A {}\nclass B {}')!;

      expect(file.lineOf(11), 2);
      expect(file.lines, hasLength(2));
    });
  });

  group('groupLibraries', () {
    const resolver = UriResolver({});

    List<String> describe(Map<String, String> sources) => [
      for (final library in groupLibraries([
        for (final MapEntry(:key, :value) in sources.entries)
          ParsedFile.parse(key, value)!,
      ], resolver))
        '${library.path}: ${library.parts.map((p) => p.path).join(',')}',
    ];

    test('attaches parts to their library, sorted', () {
      expect(
        describe({
          'lib/l.dart': "part 'z.dart'; part 'b.dart';",
          'lib/z.dart': "part of 'l.dart';",
          'lib/b.dart': "part of 'l.dart';",
        }),
        ['lib/l.dart: lib/b.dart,lib/z.dart'],
      );
    });

    test('treats a part of a part, or of itself, as a library', () {
      expect(
        describe({
          'lib/l.dart': "part 'p.dart';",
          'lib/p.dart': "part of 'l.dart';",
          'lib/pp.dart': "part of 'p.dart';",
          'lib/self.dart': "part of 'self.dart';",
        }),
        ['lib/l.dart: lib/p.dart', 'lib/pp.dart: ', 'lib/self.dart: '],
      );
    });

    test('keeps a part whose owner is unknown as a library', () {
      expect(describe({'lib/p.dart': 'part of unknown.library;'}), [
        'lib/p.dart: ',
      ]);
    });

    test('resolves owners through packages too', () {
      final grouped = groupLibraries([
        ParsedFile.parse('lib/l.dart', "part 'p.dart';")!,
        ParsedFile.parse('lib/p.dart', "part of 'package:a/l.dart';")!,
      ], const UriResolver({'a': ProjectPackage('a', '')}));

      expect(grouped.single.parts.single.path, 'lib/p.dart');
      expect(grouped.single.files, hasLength(2));
    });
  });
}
