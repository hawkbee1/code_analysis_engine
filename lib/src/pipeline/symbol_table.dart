import 'package:analyzer/dart/ast/ast.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:equatable/equatable.dart';

/// What a top-level declaration is.
enum DeclKind {
  /// A class (or class type alias `class A = B with C;`).
  classDecl,

  /// A mixin.
  mixinDecl,

  /// An enum.
  enumDecl,

  /// An extension.
  extensionDecl,

  /// An extension type.
  extensionTypeDecl,

  /// A top-level function.
  function,

  /// A top-level getter.
  getter,

  /// A top-level setter.
  setter,

  /// A top-level variable.
  variable,

  /// A typedef.
  typeAlias,
}

/// What a class member is.
enum MemberDeclKind {
  /// A method or operator.
  method,

  /// A constructor (incl. primary constructors).
  constructor,

  /// A getter.
  getter,

  /// A setter.
  setter,

  /// A field.
  field,
}

/// A member of a type declaration.
class MemberDecl {
  /// Creates a member.
  new({
    required this.kind,
    required this.name,
    required this.node,
    this.isStatic = false,
    this.type,
  });

  /// What it is.
  final MemberDeclKind kind;

  /// Its name (`new` for unnamed constructors).
  final String name;

  /// Its syntax node.
  final AstNode node;

  /// Whether it is static.
  final bool isStatic;

  /// Declared type: field type, getter/method return type.
  final TypeAnnotation? type;

  /// Whether its name is private.
  bool get isPrivate => name.startsWith('_');
}

/// A top-level declaration.
class Declaration {
  /// Creates a declaration.
  new({
    required this.kind,
    required this.name,
    required this.libraryPath,
    required this.file,
    required this.node,
    this.superclass,
    this.interfaces = const [],
    this.mixins = const [],
    this.members = const [],
    this.displayName,
    this.type,
  });

  /// What it is.
  final DeclKind kind;

  /// Its name (`extension@<line>` for unnamed extensions).
  final String name;

  /// Shown instead of [name] when set (unnamed extensions).
  final String? displayName;

  /// The library it belongs to.
  final String libraryPath;

  /// The file it is written in (a part, or the defining file).
  final ParsedFile file;

  /// Its syntax node.
  final AstNode node;

  /// The `extends` type of a class.
  final NamedType? superclass;

  /// `implements` types.
  final List<NamedType> interfaces;

  /// `with` types.
  final List<NamedType> mixins;

  /// Members of a type declaration.
  final List<MemberDecl> members;

  /// Declared type of a variable, return type of a function or getter.
  final TypeAnnotation? type;

  /// Whether its name is private.
  bool get isPrivate => name.startsWith('_');
}

/// An `import` directive.
class ImportInfo {
  /// Creates an import.
  const new(this.target, {this.prefix, this.show, this.hide = const {}});

  /// What it imports.
  final UriTarget target;

  /// `as` prefix.
  final String? prefix;

  /// `show` names, or null when there is no `show`.
  final Set<String>? show;

  /// `hide` names.
  final Set<String> hide;

  /// Whether [name] passes the `show` / `hide` combinators.
  bool allows(String name) =>
      (show == null || show!.contains(name)) && !hide.contains(name);
}

/// Everything known about one library.
class LibraryInfo {
  /// Creates a library.
  new({
    required this.path,
    required this.declarations,
    required this.imports,
    required this.exports,
  });

  /// Path of its defining file.
  final String path;

  /// Its declarations, private ones included, by name.
  final Map<String, Declaration> declarations;

  /// Its imports.
  final List<ImportInfo> imports;

  /// Its exports (an export uses [ImportInfo] without prefix).
  final List<ImportInfo> exports;
}

/// The result of looking up a name (a type, function or variable).
sealed class SymbolLookup extends Equatable {
  const new();
}

/// A declaration of the project.
class ProjectSymbol extends SymbolLookup {
  /// Creates the result.
  const new(this.declaration);

  /// The declaration.
  final Declaration declaration;

  @override
  List<Object?> get props => [declaration];
}

/// A name from outside the project; [packageName] is a best guess
/// (`unknown` when several imported packages could provide it).
class ExternalSymbol extends SymbolLookup {
  /// Creates the result.
  const new(this.packageName);

  /// The package the name most likely comes from (`dart` for the SDK).
  final String packageName;

  @override
  List<Object?> get props => [packageName];
}

/// The name is not visible (e.g. an unknown prefix).
class SymbolNotFound extends SymbolLookup {
  /// Creates the result.
  const new();

  @override
  List<Object?> get props => [];
}

/// Declarations of every library, and what each library can see.
class SymbolTable {
  /// Builds the table from [libraries].
  factory build(List<ParsedLibrary> libraries, UriResolver resolver) {
    final infos = <String, LibraryInfo>{};
    for (final library in libraries) {
      infos[library.path] = _readLibrary(library, resolver);
    }
    return SymbolTable._(infos);
  }

  new _(this.libraries);

  /// Package of well-known external types, used when several imported
  /// packages could provide a name. Parse-only mode cannot know better.
  static const knownExternalTypes = {
    'StatelessWidget': 'flutter',
    'StatefulWidget': 'flutter',
    'State': 'flutter',
    'Widget': 'flutter',
    'InheritedWidget': 'flutter',
    'ChangeNotifier': 'flutter',
    'CustomPainter': 'flutter',
    'Bloc': 'bloc',
    'Cubit': 'bloc',
    'BlocObserver': 'bloc',
    'Equatable': 'equatable',
    'Exception': 'dart',
    'Error': 'dart',
    'StateError': 'dart',
  };

  /// Every library, by path.
  final Map<String, LibraryInfo> libraries;

  final _exportNamespaces = <String, Map<String, Declaration>>{};

  /// What library [path] exports: its public declarations plus, through its
  /// `export` directives (transitively, cycle-safe), those of other project
  /// libraries.
  Map<String, Declaration> exportNamespace(String path) =>
      _exportNamespace(path, <String>{});

  Map<String, Declaration> _exportNamespace(String path, Set<String> visiting) {
    final cached = _exportNamespaces[path];
    if (cached != null) return cached;
    final library = libraries[path];
    if (library == null || !visiting.add(path)) return const {};
    final namespace = <String, Declaration>{
      for (final MapEntry(:key, :value) in library.declarations.entries)
        if (!value.isPrivate) key: value,
    };
    for (final export in library.exports) {
      final target = export.target;
      if (target is! ProjectLibrary) continue;
      for (final MapEntry(:key, :value) in _exportNamespace(
        target.path,
        visiting,
      ).entries) {
        if (export.allows(key)) namespace.putIfAbsent(key, () => value);
      }
    }
    visiting.remove(path);
    return _exportNamespaces[path] = namespace;
  }

  /// Looks up [name] (with [prefix] for `prefix.name`) as seen from library
  /// [libraryPath]: own declarations first, then imported project libraries
  /// (through their export namespaces), else an external guess.
  SymbolLookup lookup(String libraryPath, String name, {String? prefix}) {
    final library = libraries[libraryPath];
    if (library == null) return const SymbolNotFound();
    if (prefix == null) {
      final own = library.declarations[name];
      if (own != null) return ProjectSymbol(own);
    }
    final imports = library.imports.where((i) => i.prefix == prefix).toList();
    if (prefix != null && imports.isEmpty) return const SymbolNotFound();
    for (final import in imports) {
      final target = import.target;
      if (target is ProjectLibrary && import.allows(name)) {
        final found = exportNamespace(target.path)[name];
        if (found != null) return ProjectSymbol(found);
      }
    }
    return ExternalSymbol(_guessPackage(name, imports));
  }

  /// Whether [name] is an import prefix in library [libraryPath].
  bool isImportPrefix(String libraryPath, String name) =>
      libraries[libraryPath]?.imports.any((i) => i.prefix == name) ?? false;

  static String _guessPackage(String name, List<ImportInfo> imports) {
    final candidates = <String>{};
    for (final import in imports) {
      final package = switch (import.target) {
        ExternalLibrary(:final packageName) => packageName,
        SdkLibrary() => 'dart',
        _ => null,
      };
      if (package == null || !import.allows(name)) continue;
      if (import.show?.contains(name) ?? false) return package;
      candidates.add(package);
    }
    final known = knownExternalTypes[name];
    if (known != null) return known;
    if (candidates.length == 1) return candidates.single;
    // Nothing imported can provide it: dart:core is imported implicitly.
    return candidates.isEmpty ? 'dart' : 'unknown';
  }

  static LibraryInfo _readLibrary(ParsedLibrary library, UriResolver resolver) {
    final declarations = <String, Declaration>{};
    for (final file in library.files) {
      for (final node in file.unit.declarations) {
        for (final decl in _declarationsOf(node, library.path, file)) {
          declarations.putIfAbsent(decl.name, () => decl);
        }
      }
    }
    final imports = <ImportInfo>[];
    final exports = <ImportInfo>[];
    for (final directive in library.definingFile.unit.directives) {
      if (directive is! NamespaceDirective) continue;
      final uri = directive.uri.stringValue;
      if (uri == null) continue;
      Set<String>? show;
      final hide = <String>{};
      for (final combinator in directive.combinators) {
        switch (combinator) {
          case ShowCombinator(:final shownNames):
            (show ??= {}).addAll(shownNames.map((n) => n.name));
          case HideCombinator(:final hiddenNames):
            hide.addAll(hiddenNames.map((n) => n.name));
        }
      }
      final target = resolver.resolve(library.path, uri);
      if (directive is ImportDirective) {
        imports.add(
          ImportInfo(
            target,
            prefix: directive.prefix?.name,
            show: show,
            hide: hide,
          ),
        );
      } else {
        exports.add(ImportInfo(target, show: show, hide: hide));
      }
    }
    return LibraryInfo(
      path: library.path,
      declarations: declarations,
      imports: imports,
      exports: exports,
    );
  }

  static Iterable<Declaration> _declarationsOf(
    CompilationUnitMember node,
    String libraryPath,
    ParsedFile file,
  ) sync* {
    Declaration type(
      DeclKind kind,
      String name, {
      NamedType? superclass,
      ImplementsClause? implementsClause,
      List<NamedType> mixins = const [],
      List<MemberDecl> members = const [],
      String? displayName,
    }) => Declaration(
      kind: kind,
      name: name,
      libraryPath: libraryPath,
      file: file,
      node: node,
      superclass: superclass,
      interfaces: implementsClause?.interfaces.toList() ?? const [],
      mixins: mixins,
      members: members,
      displayName: displayName,
    );

    switch (node) {
      case ClassDeclaration():
        yield type(
          DeclKind.classDecl,
          node.namePart.typeName.lexeme,
          superclass: node.extendsClause?.superclass,
          implementsClause: node.implementsClause,
          mixins: node.withClause?.mixinTypes.toList() ?? const [],
          members: _members(node.body.members, primary: node.namePart),
        );
      case ClassTypeAlias():
        yield type(
          DeclKind.classDecl,
          node.name.lexeme,
          superclass: node.superclass,
          implementsClause: node.implementsClause,
          mixins: node.withClause.mixinTypes.toList(),
        );
      case MixinDeclaration():
        yield type(
          DeclKind.mixinDecl,
          node.name.lexeme,
          implementsClause: node.implementsClause,
          members: _members(node.body.members),
        );
      case EnumDeclaration():
        yield type(
          DeclKind.enumDecl,
          node.namePart.typeName.lexeme,
          implementsClause: node.implementsClause,
          mixins: node.withClause?.mixinTypes.toList() ?? const [],
          members: _members(node.body.members, primary: node.namePart),
        );
      case ExtensionDeclaration():
        final name = node.name?.lexeme;
        yield type(
          DeclKind.extensionDecl,
          name ?? 'extension@${file.lineOf(node.offset)}',
          displayName: name == null
              ? 'extension on ${node.onClause?.extendedType.toSource()}'
              : null,
          members: _members(node.body.members),
        );
      case ExtensionTypeDeclaration():
        yield type(
          DeclKind.extensionTypeDecl,
          node.namePart.typeName.lexeme,
          implementsClause: node.implementsClause,
          members: _members(node.body.members, primary: node.namePart),
        );
      case FunctionDeclaration():
        yield Declaration(
          kind: node.isGetter
              ? DeclKind.getter
              : node.isSetter
              ? DeclKind.setter
              : DeclKind.function,
          name: node.name.lexeme,
          libraryPath: libraryPath,
          file: file,
          node: node,
          type: node.returnType,
        );
      case TopLevelVariableDeclaration():
        for (final variable in node.variables.variables) {
          yield Declaration(
            kind: DeclKind.variable,
            name: variable.name.lexeme,
            libraryPath: libraryPath,
            file: file,
            node: variable,
            type: node.variables.type,
          );
        }
      case TypeAlias():
        yield type(DeclKind.typeAlias, node.name.lexeme);
    }
  }

  static List<MemberDecl> _members(
    List<ClassMember> members, {
    ClassNamePart? primary,
  }) => [
    if (primary is PrimaryConstructorDeclaration)
      MemberDecl(
        kind: MemberDeclKind.constructor,
        name: primary.constructorName?.name.lexeme ?? 'new',
        node: primary,
      ),
    for (final member in members) ..._memberDecls(member),
  ];

  static Iterable<MemberDecl> _memberDecls(ClassMember member) sync* {
    switch (member) {
      case ConstructorDeclaration():
        yield MemberDecl(
          kind: MemberDeclKind.constructor,
          name: member.name?.lexeme ?? 'new',
          node: member,
        );
      case MethodDeclaration():
        yield MemberDecl(
          kind: member.isGetter
              ? MemberDeclKind.getter
              : member.isSetter
              ? MemberDeclKind.setter
              : MemberDeclKind.method,
          name: member.name.lexeme,
          node: member,
          isStatic: member.isStatic,
          type: member.returnType,
        );
      case FieldDeclaration():
        for (final variable in member.fields.variables) {
          yield MemberDecl(
            kind: MemberDeclKind.field,
            name: variable.name.lexeme,
            node: variable,
            isStatic: member.isStatic,
            type: member.fields.type,
          );
        }
      default:
        break;
    }
  }
}
