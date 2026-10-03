import 'package:code_analysis_engine/src/pipeline/metrics.dart';
import 'package:test/test.dart';

int _loc(String source) {
  final lines = source.split('\n');
  return linesOfCode(lines, 1, lines.length);
}

void main() {
  group('linesOfCode', () {
    test('ignores blank and comment-only lines', () {
      expect(_loc('a();\n\n   \n// x\n/// doc\n\tb();'), 2);
    });

    test('ignores block comments spanning lines', () {
      expect(_loc('/*\n a\n b */\nc();\n/* one line */'), 1);
    });

    test('counts code before and after block comments', () {
      expect(_loc('/* a */ b();\nc(); /* open\nstill comment\n*/ d();'), 3);
    });

    test('counts code followed by a closed block comment once', () {
      expect(_loc('a(); /* closed */\nb();'), 2);
    });

    test('stops at the last line of the source', () {
      expect(linesOfCode(['a();'], 1, 10), 1);
    });
  });
}
