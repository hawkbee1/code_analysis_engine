import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_source_client/code_source_client.dart';
import 'package:equatable/equatable.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// A package of the analyzed project: a folder with a `pubspec.yaml`.
class ProjectPackage extends Equatable {
  /// Creates a package named [name] whose folder is [root] (`''` for the
  /// root of the snapshot).
  const new(this.name, this.root);

  /// The package name from its pubspec.
  final String name;

  /// Its folder, relative to the snapshot root (`''` at the root).
  final String root;

  /// Path of `lib/<path>` of this package.
  String libPath(String path) => root.isEmpty ? 'lib/$path' : '$root/lib/$path';

  @override
  List<Object?> get props => [name, root];
}

/// The files and packages an analysis works on.
class CollectedFiles {
  /// Creates the result.
  new({required this.dartFiles, required this.packages});

  /// The Dart files to analyze, sorted.
  final List<String> dartFiles;

  /// The project packages, by name.
  final Map<String, ProjectPackage> packages;

  /// The deepest package whose folder contains [path], or null.
  ProjectPackage? packageOf(String path) {
    ProjectPackage? best;
    for (final package in packages.values) {
      final inside =
          package.root.isEmpty || path.startsWith('${package.root}/');
      if (inside && (best == null || package.root.length > best.root.length)) {
        best = package;
      }
    }
    return best;
  }
}

/// Stage 1: picks the files to analyze according to the file rules, and
/// finds the project packages (every `pubspec.yaml`, so a monorepo is one
/// project with several packages).
class FileCollector {
  /// Creates a collector for [rules].
  new(AnalysisRules rules)
    : _generated = rules.excludeGenerated
          ? [for (final g in rules.generatedPatterns) _glob(g)]
          : const [],
      _excludeTests = rules.excludeTests,
      _extra = [for (final g in rules.extraExcludes) _glob(g)];

  static Glob _glob(String pattern) => Glob(pattern, context: p.posix);

  static const _testFolders = {'test', 'integration_test', 'test_driver'};
  static final _pubspecName = RegExp(
    r'^name:\s*([A-Za-z_][A-Za-z0-9_]*)',
    multiLine: true,
  );

  final List<Glob> _generated;
  final bool _excludeTests;
  final List<Glob> _extra;

  /// Whether [path] (a `.dart` file) is analyzed.
  bool includes(String path) {
    final segments = path.split('/');
    final folders = segments.take(segments.length - 1);
    if (folders.any(FileFilter.skipsFolder)) return false;
    if (_excludeTests &&
        (folders.any(_testFolders.contains) ||
            segments.last.endsWith('_test.dart'))) {
      return false;
    }
    return !_generated.any((g) => g.matches(path)) &&
        !_extra.any((g) => g.matches(path));
  }

  /// Collects the files of [snapshot].
  Future<CollectedFiles> collect(SourceSnapshot snapshot) async {
    final packages = <String, ProjectPackage>{};
    for (final path in snapshot.paths) {
      if (p.posix.basename(path) != 'pubspec.yaml') continue;
      final folders = path.split('/')..removeLast();
      if (folders.any(FileFilter.skipsFolder)) continue;
      final match = _pubspecName.firstMatch(await snapshot.readAsString(path));
      if (match == null) continue;
      final name = match.group(1)!;
      // Two pubspecs with the same name (e.g. copies): keep the shallowest.
      final root = folders.join('/');
      final existing = packages[name];
      if (existing == null || root.length < existing.root.length) {
        packages[name] = ProjectPackage(name, root);
      }
    }
    return CollectedFiles(
      dartFiles: [
        for (final path in snapshot.paths)
          if (path.endsWith('.dart') && includes(path)) path,
      ]..sort(),
      packages: packages,
    );
  }
}
