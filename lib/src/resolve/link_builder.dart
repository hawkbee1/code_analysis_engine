import 'package:analyzer/dart/ast/ast.dart' show NamedType;
import 'package:code_analysis_engine/src/pipeline/containment.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:code_analysis_engine/src/resolve/reference_resolver.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_graph/code_graph.dart';
import 'package:equatable/equatable.dart';

/// How the call sites of an analysis were resolved. It measures the quality
/// of parse-only resolution (getter reads are counted separately).
class CallSiteStats extends Equatable {
  /// Creates the counters.
  const new({
    this.exact = 0,
    this.byName = 0,
    this.ambiguous = 0,
    this.external = 0,
    this.unresolved = 0,
    this.getterLinks = 0,
    this.skippedTopLevel = 0,
  });

  /// Calls resolved from declared types.
  final int exact;

  /// Calls linked to the only project method with that name.
  final int byName;

  /// Calls linked to several candidates.
  final int ambiguous;

  /// Calls into external packages.
  final int external;

  /// Calls without a target.
  final int unresolved;

  /// Getter reads linked to a getter sphere.
  final int getterLinks;

  /// Calls in top-level variable initializers, skipped.
  final int skippedTopLevel;

  /// Every call site counted.
  int get total => exact + byName + ambiguous + external + unresolved;

  @override
  List<Object?> get props => [
    exact,
    byName,
    ambiguous,
    external,
    unresolved,
    getterLinks,
    skippedTopLevel,
  ];

  @override
  String toString() =>
      'CallSiteStats(exact: $exact, byName: $byName, ambiguous: $ambiguous, '
      'external: $external, unresolved: $unresolved, getterLinks: '
      '$getterLinks, skippedTopLevel: $skippedTopLevel)';
}

/// Collects resolved references and turns them into links.
class LinkBuilder {
  /// Creates a builder for a graph whose nodes are [nodes].
  new(this.nodes);

  /// The graph's nodes (links to missing nodes are dropped).
  final Map<String, CodeNode> nodes;

  final _links = <String, CodeLink>{};
  var _exact = 0;
  var _byName = 0;
  var _ambiguous = 0;
  var _external = 0;
  var _unresolved = 0;
  var _getterLinks = 0;

  /// Records the result of one site (see `ReferenceSink`).
  void addReference(
    String fromId,
    ResolvedReference reference, {
    required bool isCall,
  }) {
    switch (reference) {
      case ResolvedToNode(:final nodeId, :final resolution):
        if (isCall) {
          resolution == LinkResolution.exact ? _exact++ : _byName++;
        } else {
          _getterLinks++;
        }
        _add(fromId, nodeId, LinkKind.call, resolution);
      case ResolvedAmbiguous(:final candidateIds):
        if (isCall) _ambiguous++;
        for (final id in candidateIds) {
          _add(fromId, id, LinkKind.call, LinkResolution.ambiguous);
        }
      case ResolvedExternal(:final packageName):
        if (isCall) _external++;
        _add(
          fromId,
          'pkg:$packageName',
          LinkKind.call,
          LinkResolution.external,
        );
      case Unresolved():
        if (isCall) _unresolved++;
    }
  }

  /// Adds `extendsExternal` links (classes extending an external class while
  /// ghost parents are off).
  void addExternalSuperclasses(Containment containment) {
    for (final MapEntry(key: id, value: package)
        in containment.externalSuperclasses.entries) {
      _add(
        id,
        'pkg:$package',
        LinkKind.extendsExternal,
        LinkResolution.external,
      );
    }
  }

  /// Adds `implements` and `with` links, according to [rules].
  void addTypeRelations(
    SymbolTable symbols,
    Map<Declaration, String?> nodeIds,
    AnalysisRules rules,
  ) {
    for (final MapEntry(key: declaration, value: id) in nodeIds.entries) {
      if (id == null) continue;
      void relate(List<NamedTypeLike> types, LinkKind kind) {
        for (final type in types) {
          switch (symbols.lookup(
            declaration.libraryPath,
            type.name,
            prefix: type.prefix,
          )) {
            case ProjectSymbol(:final declaration):
              final target = nodeIds[declaration];
              if (target != null) _add(id, target, kind, LinkResolution.exact);
            case ExternalSymbol(:final packageName):
              _add(id, 'pkg:$packageName', kind, LinkResolution.external);
            case SymbolNotFound():
              break;
          }
        }
      }

      if (rules.linksImplements) {
        relate([
          for (final t in declaration.interfaces) NamedTypeLike.of(t),
        ], LinkKind.implementsLink);
      }
      if (rules.linksMixins) {
        relate([
          for (final t in declaration.mixins) NamedTypeLike.of(t),
        ], LinkKind.mixinLink);
      }
    }
  }

  /// Adds one `import` link per import of each library: from the largest
  /// declaration of the importing file to the largest of the imported file,
  /// or to the external package.
  void addImports(List<ParsedLibrary> libraries, SymbolTable symbols) {
    final representatives = _fileRepresentatives();
    for (final library in libraries) {
      final from = representatives[library.path];
      if (from == null) continue;
      for (final import in symbols.libraries[library.path]!.imports) {
        final to = switch (import.target) {
          ProjectLibrary(:final path) => representatives[path],
          ExternalLibrary(:final packageName) => 'pkg:$packageName',
          SdkLibrary() => 'pkg:dart',
          UnresolvedUri() => null,
        };
        if (to == null) continue;
        _add(
          from,
          to,
          LinkKind.import,
          import.target is ProjectLibrary
              ? LinkResolution.exact
              : LinkResolution.external,
        );
      }
    }
  }

  /// The largest declaration written in each file (not a member: a node
  /// whose parent is absent, external, or written in another file).
  Map<String, String> _fileRepresentatives() {
    final best = <String, CodeNode>{};
    for (final node in nodes.values) {
      final file = node.location?.filePath;
      if (file == null) continue;
      final parent = node.parentId == null ? null : nodes[node.parentId];
      final isMember =
          parent != null &&
          !parent.isExternal &&
          parent.location?.filePath == file;
      if (isMember) continue;
      final current = best[file];
      if (current == null || node.loc > current.loc) best[file] = node;
    }
    return {for (final MapEntry(:key, :value) in best.entries) key: value.id};
  }

  void _add(String from, String to, LinkKind kind, LinkResolution resolution) {
    if (from == to || !nodes.containsKey(to) || !nodes.containsKey(from)) {
      return;
    }
    final key = '$from\u0000$to\u0000${kind.index}';
    final existing = _links[key];
    _links[key] = existing == null
        ? CodeLink(fromId: from, toId: to, kind: kind, resolution: resolution)
        : CodeLink(
            fromId: from,
            toId: to,
            kind: kind,
            // Keep the strongest resolution seen for this pair.
            resolution: resolution.index < existing.resolution.index
                ? resolution
                : existing.resolution,
            count: existing.count + 1,
          );
  }

  /// The links, merged and sorted by source, target and kind.
  List<CodeLink> build() => _links.values.toList()
    ..sort((a, b) {
      final byFrom = a.fromId.compareTo(b.fromId);
      if (byFrom != 0) return byFrom;
      final byTo = a.toId.compareTo(b.toId);
      return byTo != 0 ? byTo : a.kind.index.compareTo(b.kind.index);
    });

  /// The call site counters; [skippedTopLevel] comes from the collector.
  CallSiteStats stats({int skippedTopLevel = 0}) => CallSiteStats(
    exact: _exact,
    byName: _byName,
    ambiguous: _ambiguous,
    external: _external,
    unresolved: _unresolved,
    getterLinks: _getterLinks,
    skippedTopLevel: skippedTopLevel,
  );
}

/// The name and prefix of a type reference.
class NamedTypeLike {
  /// Creates the reference.
  const new(this.name, this.prefix);

  /// Reads them from a syntax node.
  factory of(NamedType namedType) =>
      NamedTypeLike(namedType.name.lexeme, namedType.importPrefix?.name.lexeme);

  /// The type name.
  final String name;

  /// Its import prefix.
  final String? prefix;
}

/// Adds annotations to a finished graph (architecture §5.1 stage 8). The MVP
/// ships none; future design-pattern detectors (Bloc, Repository, …) will.
abstract interface class GraphAnnotator {
  /// Returns [graph] with annotations added.
  CodeGraph annotate(CodeGraph graph);
}
