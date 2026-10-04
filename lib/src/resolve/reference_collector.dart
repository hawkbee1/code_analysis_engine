import 'package:analyzer/dart/ast/ast.dart' hide Declaration;
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/resolve/reference_resolver.dart';

/// Receives each resolved site: the node the link starts from, the result,
/// and whether the site is a call (not a getter read).
typedef ReferenceSink = void Function(
  String fromId,
  ResolvedReference reference, {
  required bool isCall,
});

/// Walks function, method and constructor bodies (and field initializers),
/// keeping track of local variables, and asks the [resolver] about every
/// call, instance creation, constructor redirection and getter read.
///
/// Sites are resolved while walking, with the live scope, instead of being
/// collected first: AltMe-sized projects have hundreds of thousands of them.
class ReferenceCollector {
  /// Creates a collector.
  new({required this.resolver, required this.context, required this.sink});

  /// The strategy that resolves sites.
  final ReferenceResolver resolver;

  /// What earlier stages produced.
  final ResolverContext context;

  /// Where results go.
  final ReferenceSink sink;

  /// Calls in top-level variable initializers: skipped in the MVP (there is
  /// no node to start a link from), counted here.
  int skippedTopLevelSites = 0;

  late final Map<AstNode, Declaration> _declarationsByNode = {
    for (final library in context.symbols.libraries.values)
      for (final declaration in library.declarations.values)
        declaration.node: declaration,
  };

  /// Walks every file of [library].
  void collect(ParsedLibrary library) {
    for (final file in library.files) {
      for (final member in file.unit.declarations) {
        _collectMember(member, library.path);
      }
    }
  }

  void _collectMember(CompilationUnitMember member, String library) {
    switch (member) {
      case FunctionDeclaration():
        final id = context.nodeIdsByAst[member];
        if (id == null) return;
        _BodyVisitor(
          this,
          library,
          id,
          null,
        ).visitFunction(member.functionExpression);
      case TopLevelVariableDeclaration():
        final counter = _SiteCounter();
        member.accept(counter);
        skippedTopLevelSites += counter.count;
      case ClassDeclaration(body: ClassBody(:final members)) ||
          MixinDeclaration(body: ClassBody(:final members)) ||
          ExtensionDeclaration(body: ClassBody(:final members)) ||
          ExtensionTypeDeclaration(body: ClassBody(:final members)):
        _collectType(member, members, library, const []);
      case EnumDeclaration(:final body):
        _collectType(member, body.members, library, body.constants);
      default:
        break;
    }
  }

  void _collectType(
    CompilationUnitMember node,
    List<ClassMember> members,
    String library,
    List<EnumConstantDeclaration> constants,
  ) {
    final declaration = _declarationsByNode[node];
    final typeId = context.nodeIdsByAst[node];
    if (declaration == null || typeId == null) return;
    for (final constant in constants) {
      constant.arguments?.accept(
        _BodyVisitor(this, library, typeId, declaration),
      );
    }
    for (final member in members) {
      final visitor = _BodyVisitor(
        this,
        library,
        context.nodeIdsByAst[member] ?? typeId,
        declaration,
      );
      switch (member) {
        case ConstructorDeclaration():
          visitor.visitConstructor(member);
        case MethodDeclaration():
          visitor.visitMethod(member);
        case FieldDeclaration():
          // Field initializers are attributed to the type itself.
          for (final variable in member.fields.variables) {
            variable.initializer?.accept(
              _BodyVisitor(this, library, typeId, declaration),
            );
          }
        default:
          break;
      }
    }
  }
}

/// Counts the sites in a subtree (for skipped top-level initializers).
class _SiteCounter extends RecursiveAstVisitor<void> {
  int count = 0;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    count++;
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    count++;
    super.visitInstanceCreationExpression(node);
  }
}

class _BodyVisitor extends RecursiveAstVisitor<void> implements Scope {
  new(this._collector, this._library, this._enclosingId, this._enclosingType);

  final ReferenceCollector _collector;
  final String _library;
  final String _enclosingId;
  final Declaration? _enclosingType;
  final List<Map<String, LocalVariable>> _frames = [{}];

  @override
  LocalVariable? lookup(String name) {
    for (var i = _frames.length - 1; i >= 0; i--) {
      final local = _frames[i][name];
      if (local != null) return local;
    }
    return null;
  }

  void _declare(String name, LocalVariable local) => _frames.last[name] = local;

  void _inFrame(void Function() body) {
    _frames.add({});
    body();
    _frames.removeLast();
  }

  void _site(SiteKind kind, AstNode node) {
    final reference = _collector.resolver.resolve(
      ReferenceSite(
        kind: kind,
        node: node,
        enclosingNodeId: _enclosingId,
        libraryPath: _library,
        scope: this,
        enclosingType: _enclosingType,
      ),
      _collector.context,
    );
    _collector.sink(_enclosingId, reference, isCall: kind != SiteKind.getter);
  }

  void _declareParameters(FormalParameterList? parameters) {
    for (final parameter in parameters?.parameters ?? <FormalParameter>[]) {
      final name = parameter.name?.lexeme;
      if (name == null) continue;
      _declare(
        name,
        parameter is FieldFormalParameter && parameter.type == null
            ? LocalVariable(fieldName: name)
            : LocalVariable(type: parameter.type),
      );
    }
  }

  void visitFunction(FunctionExpression function) => _inFrame(() {
    _declareParameters(function.parameters);
    function.body.accept(this);
  });

  void visitMethod(MethodDeclaration method) => _inFrame(() {
    _declareParameters(method.parameters);
    method.body.accept(this);
  });

  void visitConstructor(ConstructorDeclaration constructor) => _inFrame(() {
    _declareParameters(constructor.parameters);
    for (final initializer in constructor.initializers) {
      initializer.accept(this);
    }
    constructor.body.accept(this);
  });

  // ------------------------------------------------------------- scopes

  @override
  void visitBlock(Block node) => _inFrame(() => super.visitBlock(node));

  @override
  void visitForStatement(ForStatement node) =>
      _inFrame(() => super.visitForStatement(node));

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    node.iterable.accept(this);
    final variable = node.loopVariable;
    _declare(
      variable.name.lexeme,
      variable.type == null
          ? LocalVariable(iterable: node.iterable)
          : LocalVariable(type: variable.type),
    );
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    super.visitVariableDeclaration(node);
    final list = node.parent;
    final type = list is VariableDeclarationList ? list.type : null;
    _declare(
      node.name.lexeme,
      type == null
          ? LocalVariable(initializer: node.initializer)
          : LocalVariable(type: type),
    );
  }

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    final function = node.functionDeclaration;
    _declare(function.name.lexeme, const LocalVariable(isFunction: true));
    visitFunction(function.functionExpression);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) => visitFunction(node);

  @override
  void visitCatchClause(CatchClause node) => _inFrame(() {
    if (node.exceptionParameter case final parameter?) {
      _declare(parameter.name.lexeme, LocalVariable(type: node.exceptionType));
    }
    if (node.stackTraceParameter case final parameter?) {
      _declare(parameter.name.lexeme, const LocalVariable());
    }
    node.body.accept(this);
  });

  // -------------------------------------------------------------- sites

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _site(SiteKind.invocation, node);
    // Visit the target and arguments, not the method name (no getter site).
    node.target?.accept(this);
    node.argumentList.accept(this);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _site(SiteKind.creation, node);
    node.argumentList.accept(this);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _site(SiteKind.superConstructor, node);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    _site(SiteKind.redirectingConstructor, node);
    super.visitRedirectingConstructorInvocation(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (!_isAssigned(node)) _site(SiteKind.getter, node);
    node.prefix.accept(this);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (!_isAssigned(node)) _site(SiteKind.getter, node);
    node.target?.accept(this);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // A bare reference that may be a getter: not a local, not a type name,
    // not the name part of a call, access, label or constructor.
    final parent = node.parent;
    if (parent is Label ||
        parent is ConstructorName ||
        parent is NamedType ||
        parent is SuperConstructorInvocation ||
        parent is RedirectingConstructorInvocation ||
        parent is CommentReference ||
        _isAssigned(node) ||
        lookup(node.name) != null ||
        _startsUppercase(node.name)) {
      return;
    }
    _site(SiteKind.getter, node);
  }

  static bool _isAssigned(Expression node) {
    final parent = node.parent;
    return parent is AssignmentExpression && parent.leftHandSide == node;
  }

  static bool _startsUppercase(String name) =>
      name.isNotEmpty &&
      name[0].toUpperCase() == name[0] &&
      name[0].toLowerCase() != name[0];
}
