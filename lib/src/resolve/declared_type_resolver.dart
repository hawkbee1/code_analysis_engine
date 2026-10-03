import 'package:analyzer/dart/ast/ast.dart' hide Declaration;
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/resolve/reference_resolver.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_graph/code_graph.dart';

/// A static type as far as parse-only analysis can tell.
sealed class _StaticType {
  const new(this.typeArguments, this.context);

  /// Type arguments as written, e.g. `User` in `Future<User>`.
  final List<TypeAnnotation> typeArguments;

  /// Library where the type was written, to resolve [typeArguments].
  final String context;
}

/// A type declared in the project.
final class _ProjectStaticType extends _StaticType {
  const new(this.declaration, super.typeArguments, super.context);

  final Declaration declaration;
}

/// A type from an external package.
final class _ExternalStaticType extends _StaticType {
  const new(this.name, this.packageName, super.typeArguments, super.context);

  final String name;
  final String packageName;
}

/// Resolves references from **declared types** with the project alone
/// (architecture §5.2, `parseOnly` mode): the same result on every platform.
///
/// Receiver types come from type annotations, `final a = Foo(...)`
/// initializers, `as` casts, `await` (unwrapping `Future<T>`), method and
/// getter return types, and for-in element types. Members are looked up
/// through project superclasses, mixins and interfaces. When the receiver
/// type is unknown, `links.ambiguous_calls` decides: drop the call, link it
/// to the only project method with that name (`byName`), or to every
/// candidate (`ambiguous`). Getter reads are only linked when exact.
class DeclaredTypeResolver implements ReferenceResolver {
  /// Creates the resolver.
  const new();

  @override
  ResolvedReference resolve(ReferenceSite site, ResolverContext context) =>
      _Resolution(site, context).resolve();
}

class _Resolution {
  new(this.site, this.context);

  /// Guards recursive type inference (`var a = b.c; var b = a.d;`).
  static const _maxDepth = 8;

  static const _futureTypes = {'Future', 'FutureOr'};

  /// Types that say nothing about the members of a value.
  static const _opaqueTypes = {'dynamic', 'Object', 'void', 'Never', 'Null'};

  /// Members every object has: never linked by name.
  static const _objectMembers = {
    'toString',
    'noSuchMethod',
    'hashCode',
    'runtimeType',
  };

  final ReferenceSite site;
  final ResolverContext context;

  SymbolTable get _symbols => context.symbols;
  String get _library => site.libraryPath;

  ResolvedReference resolve() {
    final node = site.node;
    return switch (site.kind) {
      SiteKind.invocation => _invocation(node as MethodInvocation),
      SiteKind.creation => _creation(node as InstanceCreationExpression),
      SiteKind.getter => _getter(node),
      SiteKind.superConstructor => _superConstructor(
        node as SuperConstructorInvocation,
      ),
      SiteKind.redirectingConstructor => _redirecting(
        node as RedirectingConstructorInvocation,
      ),
    };
  }

  // ---------------------------------------------------------------- calls

  ResolvedReference _invocation(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.realTarget;
    if (target == null) return _unqualifiedCall(name);
    if (target is SimpleIdentifier && site.scope.lookup(target.name) == null) {
      final qualifier = target.name;
      if (_symbols.isImportPrefix(_library, qualifier)) {
        return _prefixedCall(qualifier, name);
      }
      final typeLookup = _symbols.lookup(_library, qualifier);
      if (typeLookup case ProjectSymbol(:final declaration)
          when _isTypeDeclaration(declaration)) {
        return _staticCall(declaration, name);
      }
      if (typeLookup case ExternalSymbol(:final packageName)
          when _looksLikeType(qualifier)) {
        return ResolvedExternal(packageName);
      }
    }
    return _memberCall(_typeOf(target, 0), name);
  }

  ResolvedReference _unqualifiedCall(String name) {
    if (site.scope.lookup(name) != null) {
      return const Unresolved('local function or variable');
    }
    final enclosing = site.enclosingType;
    if (enclosing != null) {
      final found = _findMember(enclosing, name, const {MemberDeclKind.method});
      if (found != null) return _toMember(found, LinkResolution.exact);
    }
    switch (_symbols.lookup(_library, name)) {
      case ProjectSymbol(:final declaration):
        if (declaration.kind == DeclKind.function) {
          return _toDeclaration(declaration);
        }
        if (_isTypeDeclaration(declaration)) {
          return _constructor(declaration, 'new');
        }
        return const Unresolved('call of a variable');
      case ExternalSymbol(:final packageName):
        // A method inherited from an external superclass (`setState`) is
        // more likely than an imported top-level function.
        final inherited = enclosing == null || _looksLikeType(name)
            ? null
            : _externalSupertypePackage(enclosing, <Declaration>{});
        return ResolvedExternal(inherited ?? packageName);
      case SymbolNotFound():
        return const Unresolved('not found');
    }
  }

  ResolvedReference _prefixedCall(String prefix, String name) =>
      switch (_symbols.lookup(_library, name, prefix: prefix)) {
        ProjectSymbol(:final declaration)
            when declaration.kind == DeclKind.function =>
          _toDeclaration(declaration),
        ProjectSymbol(:final declaration)
            when _isTypeDeclaration(declaration) =>
          _constructor(declaration, 'new'),
        // The prefix exists, so the lookup is never "not found".
        ProjectSymbol() ||
        SymbolNotFound() => const Unresolved('call of a variable'),
        ExternalSymbol(:final packageName) => ResolvedExternal(packageName),
      };

  /// `Type.member()`: a static method or a named constructor.
  ResolvedReference _staticCall(Declaration type, String name) {
    for (final member in type.members) {
      if (member.name == name &&
          (member.kind == MemberDeclKind.constructor ||
              (member.kind == MemberDeclKind.method && member.isStatic))) {
        return _toMember((type, member), LinkResolution.exact);
      }
    }
    return const Unresolved('no such static member');
  }

  ResolvedReference _memberCall(_StaticType? type, String name) {
    switch (type) {
      case _ProjectStaticType(:final declaration):
        final found = _findMember(declaration, name, const {
          MemberDeclKind.method,
        });
        if (found != null) return _toMember(found, LinkResolution.exact);
        final external = _externalSupertypePackage(declaration, {});
        if (external != null) return ResolvedExternal(external);
        return _extensionOr(name, () => _byName(name));
      case _ExternalStaticType(:final packageName):
        return _extensionOr(name, () => ResolvedExternal(packageName));
      case null:
        return _byName(name);
    }
  }

  /// A project extension method named [name] when there is exactly one.
  ResolvedReference _extensionOr(
    String name,
    ResolvedReference Function() otherwise,
  ) {
    final extensions = context.extensionMethodsNamed(name);
    return extensions.length == 1
        ? ResolvedToNode(extensions.single, LinkResolution.byName)
        : otherwise();
  }

  /// The `links.ambiguous_calls` policy for an unknown receiver type.
  ResolvedReference _byName(String name) {
    if (_objectMembers.contains(name)) {
      return const Unresolved('member of every object');
    }
    final candidates = [
      ...context.methodsNamed(name),
      ...context.extensionMethodsNamed(name),
    ];
    if (candidates.isEmpty) return const Unresolved('unknown receiver');
    switch (context.rules.ambiguousCalls) {
      case AmbiguousCallPolicy.skip:
        return const Unresolved('unknown receiver');
      case AmbiguousCallPolicy.uniqueName:
        return candidates.length == 1
            ? ResolvedToNode(candidates.single, LinkResolution.byName)
            : const Unresolved('name not unique');
      case AmbiguousCallPolicy.all:
        return candidates.length == 1
            ? ResolvedToNode(candidates.single, LinkResolution.byName)
            : ResolvedAmbiguous(candidates);
    }
  }

  ResolvedReference _creation(InstanceCreationExpression node) {
    final constructorName = node.constructorName;
    final type = constructorName.type;
    final name = constructorName.name?.name ?? 'new';
    return switch (_symbols.lookup(
      _library,
      type.name.lexeme,
      prefix: type.importPrefix?.name.lexeme,
    )) {
      ProjectSymbol(:final declaration) when _isTypeDeclaration(declaration) =>
        _constructor(declaration, name),
      ProjectSymbol() => const Unresolved('not a type'),
      ExternalSymbol(:final packageName) => ResolvedExternal(packageName),
      SymbolNotFound() => const Unresolved('unknown type'),
    };
  }

  ResolvedReference _superConstructor(SuperConstructorInvocation node) {
    final enclosing = site.enclosingType;
    final superclass = enclosing?.superclass;
    if (enclosing == null || superclass == null) {
      return const Unresolved('no superclass');
    }
    return switch (_typeOfAnnotation(superclass, enclosing.libraryPath)) {
      _ProjectStaticType(:final declaration) => _constructor(
        declaration,
        node.constructorName?.name ?? 'new',
      ),
      _ExternalStaticType(:final packageName) => ResolvedExternal(packageName),
      null => const Unresolved('unknown superclass'),
    };
  }

  ResolvedReference _redirecting(RedirectingConstructorInvocation node) {
    final enclosing = site.enclosingType;
    return enclosing == null
        ? const Unresolved('no enclosing type')
        : _constructor(enclosing, node.constructorName?.name ?? 'new');
  }

  /// The constructor [name] of [type], or the type itself when the
  /// constructor is implicit or not shown as a sphere.
  ResolvedReference _constructor(Declaration type, String name) {
    for (final member in type.members) {
      if (member.kind == MemberDeclKind.constructor && member.name == name) {
        return _toMember((type, member), LinkResolution.exact);
      }
    }
    return _toDeclaration(type);
  }

  // -------------------------------------------------------------- getters

  ResolvedReference _getter(AstNode node) {
    final found = switch (node) {
      PrefixedIdentifier(:final prefix, :final identifier) => _prefixedGetter(
        prefix.name,
        identifier.name,
      ),
      PropertyAccess(:final realTarget, :final propertyName) => _getterOf(
        _typeOf(realTarget, 0),
        propertyName.name,
      ),
      SimpleIdentifier(:final name) => _bareGetter(name),
      _ => null,
    };
    return found ?? const Unresolved('no getter');
  }

  ResolvedReference? _prefixedGetter(String qualifier, String name) {
    if (site.scope.lookup(qualifier) == null) {
      if (_symbols.isImportPrefix(_library, qualifier)) {
        return _topLevelGetter(
          _symbols.lookup(_library, name, prefix: qualifier),
        );
      }
      if (_symbols.lookup(_library, qualifier)
          case ProjectSymbol(:final declaration)
          when _isTypeDeclaration(declaration)) {
        for (final member in declaration.members) {
          if (member.name == name &&
              member.isStatic &&
              member.kind == MemberDeclKind.getter) {
            return _toMember((declaration, member), LinkResolution.exact);
          }
        }
        return null;
      }
    }
    return _getterOf(_typeOfIdentifier(qualifier, 0), name);
  }

  ResolvedReference? _bareGetter(String name) {
    final enclosing = site.enclosingType;
    if (enclosing != null) {
      final found = _findMember(enclosing, name, const {MemberDeclKind.getter});
      if (found != null) return _toMember(found, LinkResolution.exact);
    }
    return _topLevelGetter(_symbols.lookup(_library, name));
  }

  ResolvedReference? _topLevelGetter(SymbolLookup lookup) => switch (lookup) {
    ProjectSymbol(:final declaration)
        when declaration.kind == DeclKind.getter =>
      _toDeclaration(declaration),
    _ => null,
  };

  ResolvedReference? _getterOf(_StaticType? type, String name) {
    if (type is _ProjectStaticType) {
      final found = _findMember(type.declaration, name, const {
        MemberDeclKind.getter,
      });
      if (found != null) return _toMember(found, LinkResolution.exact);
    }
    // e.g. `context.l10n`: a project extension getter on an external type.
    final extension = _uniqueExtensionMember(name, const {
      MemberDeclKind.getter,
    });
    return extension == null
        ? null
        : _toMember(extension, LinkResolution.byName);
  }

  /// The only project extension member named [name] of [kinds], or null.
  DeclarationMember? _uniqueExtensionMember(
    String name,
    Set<MemberDeclKind> kinds,
  ) {
    final candidates = context.extensionMembersNamed(name, kinds);
    return candidates.length == 1 ? candidates.single : null;
  }

  // ---------------------------------------------------------------- types

  _StaticType? _typeOf(Expression expression, int depth) {
    if (depth > _maxDepth) return null;
    final next = depth + 1;
    switch (expression) {
      case ParenthesizedExpression(:final expression):
        return _typeOf(expression, next);
      case ThisExpression():
        final enclosing = site.enclosingType;
        return enclosing == null
            ? null
            : _ProjectStaticType(enclosing, const [], enclosing.libraryPath);
      case SuperExpression():
        final enclosing = site.enclosingType;
        final superclass = enclosing?.superclass;
        return superclass == null
            ? null
            : _typeOfAnnotation(superclass, enclosing!.libraryPath);
      case AsExpression(:final type):
        return _typeOfAnnotation(type, _library);
      case AwaitExpression(:final expression):
        final awaited = _typeOf(expression, next);
        if (awaited is _ExternalStaticType &&
            _futureTypes.contains(awaited.name) &&
            awaited.typeArguments.isNotEmpty) {
          return _typeOfAnnotation(
            awaited.typeArguments.first,
            awaited.context,
          );
        }
        return awaited;
      case InstanceCreationExpression(:final constructorName):
        return _typeOfAnnotation(constructorName.type, _library);
      case CascadeExpression(:final target):
        return _typeOf(target, next);
      case SimpleIdentifier(:final name):
        return _typeOfIdentifier(name, next);
      case PrefixedIdentifier(:final prefix, :final identifier):
        return _typeOfPrefixed(prefix.name, identifier.name, next);
      case PropertyAccess(:final realTarget, :final propertyName):
        return _typeOfMember(_typeOf(realTarget, next), propertyName.name);
      case MethodInvocation():
        return _typeOfInvocation(expression, next);
      default:
        return null;
    }
  }

  _StaticType? _typeOfIdentifier(String name, int depth) {
    if (depth > _maxDepth) return null;
    final local = site.scope.lookup(name);
    if (local != null) return _typeOfLocal(local, depth);
    final enclosing = site.enclosingType;
    if (enclosing != null) {
      final found = _findMember(enclosing, name, const {
        MemberDeclKind.field,
        MemberDeclKind.getter,
      });
      if (found != null) return _typeOfMemberDecl(found);
    }
    return switch (_symbols.lookup(_library, name)) {
      ProjectSymbol(:final declaration)
          when declaration.kind == DeclKind.variable ||
              declaration.kind == DeclKind.getter =>
        _typeOfAnnotation(declaration.type, declaration.libraryPath),
      _ => null,
    };
  }

  _StaticType? _typeOfLocal(LocalVariable local, int depth) {
    if (local.type case final type?) return _typeOfAnnotation(type, _library);
    if (local.initializer case final initializer?) {
      return _typeOf(initializer, depth + 1);
    }
    if (local.iterable case final iterable?) {
      final iterableType = _typeOf(iterable, depth + 1);
      final element = iterableType?.typeArguments.firstOrNull;
      return element == null
          ? null
          : _typeOfAnnotation(element, iterableType!.context);
    }
    if (local.fieldName case final field?) {
      final enclosing = site.enclosingType;
      if (enclosing == null) return null;
      final found = _findMember(enclosing, field, const {MemberDeclKind.field});
      return found == null ? null : _typeOfMemberDecl(found);
    }
    return null;
  }

  _StaticType? _typeOfPrefixed(String qualifier, String name, int depth) {
    if (site.scope.lookup(qualifier) == null &&
        _symbols.isImportPrefix(_library, qualifier)) {
      return switch (_symbols.lookup(_library, name, prefix: qualifier)) {
        ProjectSymbol(:final declaration)
            when declaration.kind == DeclKind.variable ||
                declaration.kind == DeclKind.getter =>
          _typeOfAnnotation(declaration.type, declaration.libraryPath),
        _ => null,
      };
    }
    return _typeOfMember(_typeOfIdentifier(qualifier, depth), name);
  }

  _StaticType? _typeOfMember(_StaticType? type, String name) {
    const kinds = {MemberDeclKind.field, MemberDeclKind.getter};
    final found =
        (type is _ProjectStaticType
            ? _findMember(type.declaration, name, kinds)
            : null) ??
        _uniqueExtensionMember(name, const {MemberDeclKind.getter});
    return found == null ? null : _typeOfMemberDecl(found);
  }

  _StaticType? _typeOfInvocation(MethodInvocation node, int depth) {
    final name = node.methodName.name;
    final target = node.realTarget;
    // `Type()` and `Type.named()`: parse-only code has no `new` here.
    if (target == null && _looksLikeType(name)) {
      return switch (_symbols.lookup(_library, name)) {
        ProjectSymbol(:final declaration)
            when _isTypeDeclaration(declaration) =>
          _ProjectStaticType(declaration, const [], _library),
        _ => null,
      };
    }
    if (target is SimpleIdentifier &&
        _looksLikeType(target.name) &&
        site.scope.lookup(target.name) == null) {
      if (_symbols.lookup(_library, target.name)
          case ProjectSymbol(:final declaration)
          when _isTypeDeclaration(declaration)) {
        for (final member in declaration.members) {
          if (member.name != name) continue;
          if (member.kind == MemberDeclKind.constructor) {
            return _ProjectStaticType(declaration, const [], _library);
          }
          if (member.kind == MemberDeclKind.method && member.isStatic) {
            return _typeOfMemberDecl((declaration, member));
          }
        }
      }
      return null;
    }
    final DeclarationMember? found;
    if (target == null) {
      final enclosing = site.enclosingType;
      found = enclosing == null
          ? null
          : _findMember(enclosing, name, const {MemberDeclKind.method});
      if (found == null) {
        return switch (_symbols.lookup(_library, name)) {
          ProjectSymbol(:final declaration)
              when declaration.kind == DeclKind.function =>
            _typeOfAnnotation(declaration.type, declaration.libraryPath),
          _ => null,
        };
      }
    } else {
      final receiver = _typeOf(target, depth + 1);
      found = receiver is _ProjectStaticType
          ? _findMember(receiver.declaration, name, const {
              MemberDeclKind.method,
            })
          : null;
    }
    return found == null ? null : _typeOfMemberDecl(found);
  }

  /// The declared type of a field, getter or method (never a constructor).
  _StaticType? _typeOfMemberDecl(DeclarationMember found) {
    final (owner, member) = found;
    return _typeOfAnnotation(member.type, owner.libraryPath);
  }

  _StaticType? _typeOfAnnotation(TypeAnnotation? annotation, String library) {
    if (annotation is! NamedType ||
        (annotation.importPrefix == null &&
            _opaqueTypes.contains(annotation.name.lexeme))) {
      return null;
    }
    final arguments = annotation.typeArguments?.arguments.toList() ?? const [];
    return switch (_symbols.lookup(
      library,
      annotation.name.lexeme,
      prefix: annotation.importPrefix?.name.lexeme,
    )) {
      ProjectSymbol(:final declaration) when _isTypeDeclaration(declaration) =>
        _ProjectStaticType(declaration, arguments, library),
      ProjectSymbol() => null,
      ExternalSymbol(:final packageName) => _ExternalStaticType(
        annotation.name.lexeme,
        packageName,
        arguments,
        library,
      ),
      SymbolNotFound() => null,
    };
  }

  // -------------------------------------------------------------- members

  /// [name] among the members of [type] and of its project supertypes
  /// (superclass, mixins, interfaces), restricted to [kinds].
  DeclarationMember? _findMember(
    Declaration type,
    String name,
    Set<MemberDeclKind> kinds, [
    Set<Declaration>? visited,
  ]) {
    final seen = visited ?? <Declaration>{};
    if (!seen.add(type)) return null;
    for (final member in type.members) {
      if (member.name == name && kinds.contains(member.kind)) {
        return (type, member);
      }
    }
    for (final supertype in _supertypes(type)) {
      final found = _findMember(supertype, name, kinds, seen);
      if (found != null) return found;
    }
    return null;
  }

  Iterable<Declaration> _supertypes(Declaration type) sync* {
    for (final named in [
      ?type.superclass,
      ...type.mixins,
      ...type.interfaces,
    ]) {
      final resolved = _typeOfAnnotation(named, type.libraryPath);
      if (resolved is _ProjectStaticType) yield resolved.declaration;
    }
  }

  /// The package of the first external supertype of [type], searching its
  /// project supertypes too; null when every supertype is in the project.
  String? _externalSupertypePackage(Declaration type, Set<Declaration> seen) {
    if (!seen.add(type)) return null;
    for (final named in [
      ?type.superclass,
      ...type.mixins,
      ...type.interfaces,
    ]) {
      switch (_typeOfAnnotation(named, type.libraryPath)) {
        case _ExternalStaticType(:final packageName):
          return packageName;
        case _ProjectStaticType(:final declaration):
          final found = _externalSupertypePackage(declaration, seen);
          if (found != null) return found;
        case null:
          break;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- nodes

  ResolvedReference _toDeclaration(Declaration declaration) {
    final id = context.nodeIdOf(declaration);
    return id == null
        ? const Unresolved('target not shown')
        : ResolvedToNode(id, LinkResolution.exact);
  }

  /// The member's sphere, or its type's when the member is not shown.
  ResolvedReference _toMember(
    DeclarationMember found,
    LinkResolution resolution,
  ) {
    final (owner, member) = found;
    final id = context.nodeIdOfMember(member) ?? context.nodeIdOf(owner);
    return id == null
        ? const Unresolved('target not shown')
        : ResolvedToNode(id, resolution);
  }

  static bool _isTypeDeclaration(Declaration declaration) =>
      switch (declaration.kind) {
        DeclKind.classDecl ||
        DeclKind.mixinDecl ||
        DeclKind.enumDecl ||
        DeclKind.extensionTypeDecl => true,
        _ => false,
      };

  /// Dart style names types in UpperCamelCase: the only hint parse-only
  /// analysis has to tell `Foo.bar()` (static) from `foo.bar()` (instance)
  /// when `Foo` is external.
  static bool _looksLikeType(String name) {
    final first = name.startsWith(r'$') || name.startsWith('_')
        ? name.replaceFirst(RegExp(r'^[_$]+'), '')
        : name;
    return first.isNotEmpty &&
        first[0].toUpperCase() == first[0] &&
        first[0].toLowerCase() != first[0];
  }
}
