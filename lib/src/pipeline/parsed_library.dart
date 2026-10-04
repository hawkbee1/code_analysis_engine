import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';

/// A parsed Dart file.
class ParsedFile {
  /// Creates a parsed file.
  new({
    required this.path,
    required this.unit,
    required this.lineInfo,
    required this.lines,
  });

  /// Parses [content] of the file at [path]; returns null when the file has
  /// syntax errors (it is then skipped and counted in the stats).
  static ParsedFile? parse(String path, String content) {
    final result = parseString(
      content: content,
      path: '/$path',
      throwIfDiagnostics: false,
    );
    if (result.errors.isNotEmpty) return null;
    return ParsedFile(
      path: path,
      unit: result.unit,
      lineInfo: result.lineInfo,
      lines: content.split('\n'),
    );
  }

  /// Path relative to the snapshot root.
  final String path;

  /// The syntax tree.
  final CompilationUnit unit;

  /// Offset → line conversion.
  final LineInfo lineInfo;

  /// The source, split in lines.
  final List<String> lines;

  /// 1-based line of [offset].
  int lineOf(int offset) => lineInfo.getLocation(offset).lineNumber;
}

/// A library: its defining file and its `part` files.
class ParsedLibrary {
  /// Creates a library.
  new(this.definingFile, this.parts);

  /// The file that is not a `part of` another one.
  final ParsedFile definingFile;

  /// Its parts, sorted by path.
  final List<ParsedFile> parts;

  /// Path of the defining file: the library's identity.
  String get path => definingFile.path;

  /// Every file of the library, defining file first.
  List<ParsedFile> get files => [definingFile, ...parts];
}

/// Groups parsed files into libraries following `part of` directives.
///
/// A part whose owner is missing (excluded or broken) becomes a library on
/// its own, so its declarations are not lost.
List<ParsedLibrary> groupLibraries(
  List<ParsedFile> files,
  UriResolver resolver,
) {
  final byPath = {for (final f in files) f.path: f};
  final byLibraryName = <String, ParsedFile>{};
  for (final file in files) {
    final name = file.unit.directives
        .whereType<LibraryDirective>()
        .firstOrNull
        ?.name;
    if (name != null) {
      byLibraryName[name.tokens.map((t) => t.lexeme).join('.')] = file;
    }
  }

  final ownerOf = <String, String>{};
  for (final file in files) {
    final partOf = file.unit.directives
        .whereType<PartOfDirective>()
        .firstOrNull;
    if (partOf == null) continue;
    final uri = partOf.uri?.stringValue;
    String? owner;
    if (uri != null) {
      final target = resolver.resolve(file.path, uri);
      if (target is ProjectLibrary && byPath.containsKey(target.path)) {
        owner = target.path;
      }
    } else if (partOf.libraryName case final name?) {
      owner = byLibraryName[name.tokens.map((t) => t.lexeme).join('.')]?.path;
    }
    // A part of a part, or of itself, is treated as a library.
    if (owner != null && owner != file.path) ownerOf[file.path] = owner;
  }

  final parts = <String, List<ParsedFile>>{};
  for (final MapEntry(key: part, value: owner) in ownerOf.entries.toList()) {
    if (ownerOf.containsKey(owner)) {
      ownerOf.remove(part);
      continue;
    }
    (parts[owner] ??= []).add(byPath[part]!);
  }
  return [
    for (final file in files)
      if (!ownerOf.containsKey(file.path))
        ParsedLibrary(
          file,
          (parts[file.path] ?? [])..sort((a, b) => a.path.compareTo(b.path)),
        ),
  ];
}
