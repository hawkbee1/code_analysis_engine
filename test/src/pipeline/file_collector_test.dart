import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:code_analysis_engine/src/pipeline/file_collector.dart';
import 'package:test/test.dart';

import '../../helpers/fixtures.dart';

void main() {
  group(FileCollector, () {
    test('finds packages, keeping the shallowest of duplicate names', () async {
      final files = await FileCollector(AnalysisRules.defaults()).collect(
        snapshotOf({
          'pubspec.yaml': 'name: root\n',
          'packages/a/pubspec.yaml': 'description: x\nname: a\n',
          'packages/a/example/pubspec.yaml': 'name: a\n',
          'packages/nameless/pubspec.yaml': 'description: none\n',
          '.hidden/pubspec.yaml': 'name: hidden\n',
          'packages/a/lib/a.dart': '',
        }),
      );

      expect(files.packages, {
        'root': const ProjectPackage('root', ''),
        'a': const ProjectPackage('a', 'packages/a'),
      });
      expect(files.dartFiles, ['packages/a/lib/a.dart']);
    });

    test('maps a path to its deepest package', () {
      final files = CollectedFiles(
        dartFiles: const [],
        packages: const {
          'root': ProjectPackage('root', ''),
          'a': ProjectPackage('a', 'packages/a'),
        },
      );

      expect(files.packageOf('packages/a/lib/x.dart')!.name, 'a');
      expect(files.packageOf('lib/y.dart')!.name, 'root');
      expect(
        CollectedFiles(
          dartFiles: const [],
          packages: const {'a': ProjectPackage('a', 'packages/a')},
        ).packageOf('lib/y.dart'),
        isNull,
      );
    });

    test('builds the lib path of a package', () {
      expect(const ProjectPackage('a', '').libPath('a.dart'), 'lib/a.dart');
      expect(
        const ProjectPackage('a', 'p/a').libPath('a.dart'),
        'p/a/lib/a.dart',
      );
    });
  });
}
