import 'package:code_analysis_engine/src/pipeline/file_collector.dart';
import 'package:equatable/equatable.dart';
import 'package:path/path.dart' as p;

/// What an `import`, `export` or `part` URI points at.
sealed class UriTarget extends Equatable {
  const new();
}

/// A file of the analyzed project.
class ProjectLibrary extends UriTarget {
  /// Creates the target for the file at [path].
  const new(this.path);

  /// Path relative to the snapshot root.
  final String path;

  @override
  List<Object?> get props => [path];
}

/// A library of an external package (`package:<name>/…`, not in the project).
class ExternalLibrary extends UriTarget {
  /// Creates the target for package [packageName].
  const new(this.packageName);

  /// The external package.
  final String packageName;

  @override
  List<Object?> get props => [packageName];
}

/// A `dart:` library.
class SdkLibrary extends UriTarget {
  /// Creates the target for `dart:<name>`.
  const new(this.name);

  /// The library name, e.g. `async`.
  final String name;

  @override
  List<Object?> get props => [name];
}

/// A URI the engine cannot follow (other schemes, outside the snapshot).
class UnresolvedUri extends UriTarget {
  /// Creates the target for [uri].
  const new(this.uri);

  /// The URI as written.
  final String uri;

  @override
  List<Object?> get props => [uri];
}

/// Resolves URIs found in the file at a given path.
class UriResolver {
  /// Creates a resolver knowing the project [packages].
  const new(this.packages);

  /// The project packages, by name.
  final Map<String, ProjectPackage> packages;

  /// Resolves [uri] written in the file at [fromPath].
  UriTarget resolve(String fromPath, String uri) {
    if (uri.startsWith('dart:')) return SdkLibrary(uri.substring(5));
    if (uri.startsWith('package:')) {
      final rest = uri.substring(8);
      final slash = rest.indexOf('/');
      if (slash <= 0) return UnresolvedUri(uri);
      final name = rest.substring(0, slash);
      final package = packages[name];
      return package == null
          ? ExternalLibrary(name)
          : ProjectLibrary(package.libPath(rest.substring(slash + 1)));
    }
    if (uri.contains(':')) return UnresolvedUri(uri);
    final path = p.posix.normalize(
      p.posix.join(p.posix.dirname(fromPath), uri),
    );
    return path.startsWith('..') ? UnresolvedUri(uri) : ProjectLibrary(path);
  }
}
