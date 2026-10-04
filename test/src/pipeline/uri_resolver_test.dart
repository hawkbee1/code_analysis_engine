import 'package:code_analysis_engine/src/pipeline/file_collector.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:test/test.dart';

void main() {
  group(UriResolver, () {
    const resolver = UriResolver({
      'app': ProjectPackage('app', ''),
      'core': ProjectPackage('core', 'packages/core'),
    });

    test('resolves relative URIs from the file folder', () {
      expect(
        resolver.resolve('lib/src/a.dart', '../b.dart'),
        const ProjectLibrary('lib/b.dart'),
      );
      expect(
        resolver.resolve('lib/a.dart', 'src/c.dart'),
        const ProjectLibrary('lib/src/c.dart'),
      );
    });

    test('resolves project packages to their lib folder', () {
      expect(
        resolver.resolve('x.dart', 'package:app/app.dart'),
        const ProjectLibrary('lib/app.dart'),
      );
      expect(
        resolver.resolve('x.dart', 'package:core/src/e.dart'),
        const ProjectLibrary('packages/core/lib/src/e.dart'),
      );
    });

    test('recognizes external packages and the SDK', () {
      expect(
        resolver.resolve('x.dart', 'package:http/http.dart'),
        const ExternalLibrary('http'),
      );
      expect(
        resolver.resolve('x.dart', 'dart:async'),
        const SdkLibrary('async'),
      );
    });

    test('refuses what it cannot follow', () {
      for (final uri in ['package:', 'package:/x.dart', 'http://x.dart']) {
        expect(resolver.resolve('x.dart', uri), UnresolvedUri(uri));
      }
      expect(
        resolver.resolve('lib/a.dart', '../../outside.dart'),
        const UnresolvedUri('../../outside.dart'),
      );
    });
  });
}
