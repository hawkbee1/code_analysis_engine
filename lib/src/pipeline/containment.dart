import 'package:analyzer/dart/ast/ast.dart' hide Declaration;
import 'package:code_analysis_engine/src/pipeline/file_collector.dart';
import 'package:code_analysis_engine/src/pipeline/metrics.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_graph/code_graph.dart';

/// The nodes of a code graph and how they map back to the syntax.
class Containment {
  /// Creates the result.
  new({
    required this.nodes,
    required this.nodeIdsByAst,
    required this.externalSuperclasses,
    required this.entryNodeId,
  });

  /// Every node, in a deterministic order: declarations by file and offset
  /// (each followed by its members), then ghost parents, then packages.
  final Map<String, CodeNode> nodes;

  /// Node id of each declaration or member syntax node that became a node.
  final Map<AstNode, String> nodeIdsByAst;

  /// Classes extending an external class while ghost parents are off:
  /// node id → package. Session 06 turns them into `extendsExternal` links.
  final Map<String, String> externalSuperclasses;

  /// Where the camera starts, if a candidate was found.
  final String? entryNodeId;
}

class _NodeDraft {
  new({
    required this.id,
    required this.kind,
    required this.name,
    required this.qualifiedName,
    this.parentId,
    this.location,
    this.loc = 0,
    this.packageName,
  });

  final String id;
  final CodeNodeKind kind;
  final String name;
  final String qualifiedName;
  String? parentId;
  final SourceLocation? location;
  int loc;
  final String? packageName;

  CodeNode build() => CodeNode(
    id: id,
    kind: kind,
    name: name,
    qualifiedName: qualifiedName,
    parentId: parentId,
    location: location,
    loc: loc,
    packageName: packageName,
  );
}

/// Stage 4: builds the nodes and the containment tree.
///
/// Members go inside their type; `class B extends A` puts B inside A when A
/// is a project class; a class extending an external class goes inside a
/// ghost parent (or stays at the top level when ghost parents are off).
/// External packages imported anywhere become package nodes.
Containment buildContainment({
  required List<ParsedLibrary> libraries,
  required SymbolTable symbols,
  required CollectedFiles files,
  required AnalysisRules rules,
}) {
  final drafts = <String, _NodeDraft>{};
  final idsByAst = <AstNode, String>{};
  final idsByDeclaration = <Declaration, String>{};
  final memberKinds = rules.memberKinds;

  String uniqueId(String id) {
    if (!drafts.containsKey(id)) return id;
    var n = 2;
    while (drafts.containsKey('$id#$n')) {
      n++;
    }
    return '$id#$n';
  }

  SourceLocation locationOf(ParsedFile file, AstNode node) => SourceLocation(
    filePath: file.path,
    startLine: file.lineOf(node.offset),
    endLine: file.lineOf(node.end),
  );

  int locOf(ParsedFile file, AstNode node) =>
      linesOfCode(file.lines, file.lineOf(node.offset), file.lineOf(node.end));

  final declarations =
      [
        for (final library in libraries)
          ...symbols.libraries[library.path]!.declarations.values,
      ]..sort((a, b) {
        final byFile = a.file.path.compareTo(b.file.path);
        return byFile != 0 ? byFile : a.node.offset.compareTo(b.node.offset);
      });

  for (final decl in declarations) {
    final kind = _nodeKind(decl.kind);
    if (kind == null || (decl.isPrivate && !rules.includePrivate)) continue;
    final file = decl.file;
    final suffix = decl.kind == DeclKind.setter ? '=' : '';
    final id = uniqueId('${file.path}#${decl.name}$suffix');
    final packageName = files.packageOf(file.path)?.name;
    final draft = drafts[id] = _NodeDraft(
      id: id,
      kind: kind,
      name: (decl.displayName ?? decl.name) + suffix,
      qualifiedName: (decl.displayName ?? decl.name) + suffix,
      location: locationOf(file, decl.node),
      loc: locOf(file, decl.node),
      packageName: packageName,
    );
    idsByAst[decl.node] = id;
    idsByDeclaration[decl] = id;

    for (final member in decl.members) {
      final memberKind = _memberKind(member.kind, memberKinds);
      if (memberKind == null || (member.isPrivate && !rules.includePrivate)) {
        continue;
      }
      final memberSuffix = member.kind == MemberDeclKind.setter ? '=' : '';
      final qualified = '${draft.name}.${member.name}$memberSuffix';
      final memberId = uniqueId(
        '${file.path}#${decl.name}.${member.name}'
        '$memberSuffix',
      );
      final memberLoc = locOf(file, member.node);
      drafts[memberId] = _NodeDraft(
        id: memberId,
        kind: memberKind,
        name: member.name + memberSuffix,
        qualifiedName: qualified,
        parentId: id,
        location: locationOf(file, member.node),
        loc: memberLoc,
        packageName: packageName,
      );
      idsByAst[member.node] = memberId;
      // A type's own lines exclude the lines of members shown as spheres,
      // except a primary constructor, which is the type's header line.
      if (member.node is! PrimaryConstructorDeclaration) draft.loc -= memberLoc;
    }
  }

  // Superclasses: nesting in project classes, ghost parents for the others.
  final ghosts = <String, _NodeDraft>{};
  final externalSuperclasses = <String, String>{};
  for (final decl in declarations) {
    final superclass = decl.superclass;
    final id = idsByDeclaration[decl];
    if (superclass == null || id == null) continue;
    final name = superclass.name.lexeme;
    if (name == 'Object' && superclass.importPrefix == null) continue;
    final lookup = symbols.lookup(
      decl.libraryPath,
      name,
      prefix: superclass.importPrefix?.name.lexeme,
    );
    switch (lookup) {
      case ProjectSymbol(:final declaration):
        final parentId = idsByDeclaration[declaration];
        if (declaration.kind == DeclKind.classDecl &&
            parentId != null &&
            !_createsCycle(drafts, id, parentId)) {
          drafts[id]!.parentId = parentId;
        }
      case ExternalSymbol(:final packageName):
        if (rules.ghostParents) {
          final ghostId = 'ghost:$packageName:$name';
          ghosts[ghostId] ??= _NodeDraft(
            id: ghostId,
            kind: CodeNodeKind.ghostParent,
            name: name,
            qualifiedName: name,
            packageName: packageName,
          );
          drafts[id]!.parentId = ghostId;
        } else {
          externalSuperclasses[id] = packageName;
        }
      case SymbolNotFound():
        break;
    }
  }

  final packages = <String>{};
  for (final library in symbols.libraries.values) {
    for (final directive in [...library.imports, ...library.exports]) {
      switch (directive.target) {
        case ExternalLibrary(:final packageName) when rules.externalPackages:
          packages.add(packageName);
        case SdkLibrary() when rules.dartSdk:
          packages.add('dart');
        default:
          break;
      }
    }
  }

  final nodes = <String, CodeNode>{
    for (final draft in drafts.values) draft.id: draft.build(),
    for (final id in ghosts.keys.toList()..sort()) id: ghosts[id]!.build(),
    for (final name in packages.toList()..sort())
      'pkg:$name': CodeNode(
        id: 'pkg:$name',
        kind: CodeNodeKind.externalPackage,
        name: name,
        packageName: name,
      ),
  };
  return Containment(
    nodes: nodes,
    nodeIdsByAst: idsByAst,
    externalSuperclasses: externalSuperclasses,
    entryNodeId: findEntryNode(nodes, rules.entryPoint),
  );
}

/// The entry node: `main()` of [entryPoint], else of a `lib/main_*.dart`
/// (VGV flavors, `main_development` first), else any top-level `main()`
/// under `lib/`, else the largest top-level declaration, else null.
String? findEntryNode(Map<String, CodeNode> nodes, String entryPoint) {
  final mains =
      nodes.values
          .where(
            (n) =>
                n.kind == CodeNodeKind.function &&
                n.name == 'main' &&
                n.parentId == null,
          )
          .toList()
        ..sort((a, b) {
          final pa = a.location!.filePath;
          final pb = b.location!.filePath;
          final byLength = pa.length.compareTo(pb.length);
          return byLength != 0 ? byLength : pa.compareTo(pb);
        });
  String? firstMain(bool Function(String path) where) =>
      mains.where((n) => where(n.location!.filePath)).firstOrNull?.id;

  final flavor = RegExp(r'(^|/)lib/main_[^/]+\.dart$');
  return firstMain((path) => path == entryPoint) ??
      firstMain((path) => path.endsWith('/$entryPoint')) ??
      firstMain((path) => path.endsWith('lib/main_development.dart')) ??
      firstMain(flavor.hasMatch) ??
      firstMain((path) => path.startsWith('lib/') || path.contains('/lib/')) ??
      _largestTopLevel(nodes.values);
}

/// The top-level declaration with the most lines; the first one in node
/// order on a tie, so the choice is deterministic.
String? _largestTopLevel(Iterable<CodeNode> nodes) {
  CodeNode? largest;
  for (final node in nodes) {
    if (node.parentId != null || node.isExternal) continue;
    if (largest == null || node.loc > largest.loc) largest = node;
  }
  return largest?.id;
}

bool _createsCycle(
  Map<String, _NodeDraft> drafts,
  String child,
  String parent,
) {
  String? current = parent;
  while (current != null) {
    if (current == child) return true;
    current = drafts[current]?.parentId;
  }
  return false;
}

CodeNodeKind? _nodeKind(DeclKind kind) => switch (kind) {
  DeclKind.classDecl => CodeNodeKind.classDecl,
  DeclKind.mixinDecl => CodeNodeKind.mixinDecl,
  DeclKind.enumDecl => CodeNodeKind.enumDecl,
  DeclKind.extensionDecl => CodeNodeKind.extensionDecl,
  DeclKind.extensionTypeDecl => CodeNodeKind.extensionTypeDecl,
  DeclKind.function => CodeNodeKind.function,
  DeclKind.getter => CodeNodeKind.getter,
  DeclKind.setter => CodeNodeKind.setter,
  DeclKind.variable || DeclKind.typeAlias => null,
};

CodeNodeKind? _memberKind(MemberDeclKind kind, Set<MemberKind> shown) =>
    switch (kind) {
      MemberDeclKind.method when shown.contains(MemberKind.method) =>
        CodeNodeKind.method,
      MemberDeclKind.constructor when shown.contains(MemberKind.constructor) =>
        CodeNodeKind.constructor,
      MemberDeclKind.getter when shown.contains(MemberKind.getter) =>
        CodeNodeKind.getter,
      MemberDeclKind.setter when shown.contains(MemberKind.setter) =>
        CodeNodeKind.setter,
      _ => null,
    };
