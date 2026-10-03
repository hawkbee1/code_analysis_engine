import 'package:analyzer/dart/ast/ast.dart' hide Declaration;
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_graph/code_graph.dart';
import 'package:equatable/equatable.dart';

/// What kind of reference a [ReferenceSite] is.
enum SiteKind {
  /// `f()`, `a.m()`, `Type.m()`, `prefix.f()`, `Type()` (parse-only code has
  /// no instance creation without `new`/`const`: `Type()` is an invocation).
  invocation,

  /// `new Type()`, `const Type.named()`.
  creation,

  /// A getter read: `a.b`, `Type.b`, or a bare `b`.
  getter,

  /// `super(…)` / `super.named(…)` in a constructor initializer.
  superConstructor,

  /// `this(…)` / `this.named(…)` in a constructor initializer.
  redirectingConstructor,
}

/// A local variable or parameter, as written: resolvers infer its type.
class LocalVariable {
  /// Creates a local; at most one of the sources of its type is set.
  const new({
    this.type,
    this.initializer,
    this.iterable,
    this.fieldName,
    this.isFunction = false,
  });

  /// Declared type.
  final TypeAnnotation? type;

  /// Initializer of an untyped variable (`final a = Foo();`).
  final Expression? initializer;

  /// Iterable of a for-in loop variable.
  final Expression? iterable;

  /// Field of a `this.field` constructor parameter.
  final String? fieldName;

  /// Whether it is a local function.
  final bool isFunction;
}

/// The local variables visible at a site.
abstract interface class Scope {
  /// The innermost local named [name], or null.
  LocalVariable? lookup(String name);
}

/// One place in the code that refers to something callable.
class ReferenceSite {
  /// Creates a site.
  const new({
    required this.kind,
    required this.node,
    required this.enclosingNodeId,
    required this.libraryPath,
    required this.scope,
    this.enclosingType,
  });

  /// What kind of reference it is.
  final SiteKind kind;

  /// The syntax node: a `MethodInvocation`, `InstanceCreationExpression`,
  /// `PrefixedIdentifier`, `PropertyAccess`, `SimpleIdentifier`,
  /// `SuperConstructorInvocation` or `RedirectingConstructorInvocation`.
  final AstNode node;

  /// The node the link would start from (method, function, or class).
  final String enclosingNodeId;

  /// The library the site is in.
  final String libraryPath;

  /// The type declaration enclosing the site, if any.
  final Declaration? enclosingType;

  /// The locals visible at the site (valid only during resolution).
  final Scope scope;
}

/// What a reference points at.
sealed class ResolvedReference extends Equatable {
  const new();
}

/// A node of the graph; [resolution] is `exact` or `byName`.
class ResolvedToNode extends ResolvedReference {
  /// Creates the result.
  const new(this.nodeId, this.resolution);

  /// The target node.
  final String nodeId;

  /// How sure the resolver is.
  final LinkResolution resolution;

  @override
  List<Object?> get props => [nodeId, resolution];
}

/// Several project members could be the target.
class ResolvedAmbiguous extends ResolvedReference {
  /// Creates the result.
  const new(this.candidateIds);

  /// The candidate nodes.
  final List<String> candidateIds;

  @override
  List<Object?> get props => [candidateIds];
}

/// Something in an external package.
class ResolvedExternal extends ResolvedReference {
  /// Creates the result.
  const new(this.packageName);

  /// The package (`dart` for the SDK, `unknown` when unknown).
  final String packageName;

  @override
  List<Object?> get props => [packageName];
}

/// No target (a local function, an unknown receiver with the `skip` policy…).
class Unresolved extends ResolvedReference {
  /// Creates the result.
  const new(this.reason);

  /// Why, for debugging.
  final String reason;

  @override
  List<Object?> get props => [reason];
}

/// Read access to what the previous stages produced.
class ResolverContext {
  /// Creates the context.
  new({required this.symbols, required this.nodeIdsByAst, required this.rules});

  /// Declarations and namespaces.
  final SymbolTable symbols;

  /// Node id of each declaration or member syntax node shown as a sphere.
  final Map<AstNode, String> nodeIdsByAst;

  /// The analysis rules.
  final AnalysisRules rules;

  /// Node id of [declaration], or null when it is not a sphere.
  String? nodeIdOf(Declaration declaration) => nodeIdsByAst[declaration.node];

  /// Node id of [member], or null when it is not a sphere.
  String? nodeIdOfMember(MemberDecl member) => nodeIdsByAst[member.node];

  late final Map<String, List<String>> _methodsByName = _index(
    (d) => d.kind != DeclKind.extensionDecl,
  );

  late final Map<String, List<String>> _extensionMethodsByName = _index(
    (d) => d.kind == DeclKind.extensionDecl,
  );

  Map<String, List<String>> _index(bool Function(Declaration) where) {
    final index = <String, List<String>>{};
    for (final library in symbols.libraries.values) {
      for (final declaration in library.declarations.values.where(where)) {
        for (final member in declaration.members) {
          if (member.kind != MemberDeclKind.method) continue;
          final id = nodeIdOfMember(member);
          if (id != null) (index[member.name] ??= []).add(id);
        }
      }
    }
    return index;
  }

  /// Node ids of the project methods named [name] (extensions excluded).
  List<String> methodsNamed(String name) => _methodsByName[name] ?? const [];

  /// Node ids of the project extension methods named [name].
  List<String> extensionMethodsNamed(String name) =>
      _extensionMethodsByName[name] ?? const [];
}

/// Finds what a [ReferenceSite] refers to (architecture §5.2).
///
/// The MVP implementation is `DeclaredTypeResolver` (parse only). A future
/// `AnalyzerResolver` will use the analyzer's full type resolution (see
/// docs/dart_code_3d/future.md). Nothing outside `lib/src/resolve/` may
/// depend on a concrete resolver: the pipeline only consumes
/// [ResolvedReference]s.
abstract interface class ReferenceResolver {
  /// Resolves [site].
  ResolvedReference resolve(ReferenceSite site, ResolverContext context);
}
