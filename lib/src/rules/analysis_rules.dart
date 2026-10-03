import 'package:code_analysis_engine/src/rules/rule_catalog.dart';
import 'package:code_analysis_engine/src/rules/rule_parameter.dart';
import 'package:equatable/equatable.dart';

/// What to do with a call whose receiver type is unknown.
enum AmbiguousCallPolicy {
  /// Drop it.
  skip,

  /// Link it when exactly one project member has that name.
  uniqueName,

  /// Link it to every project member with that name.
  all,
}

/// Class members that can become spheres.
enum MemberKind {
  /// Methods.
  method,

  /// Constructors.
  constructor,

  /// Getters.
  getter,

  /// Setters.
  setter,
}

/// How references are resolved (architecture §5.2).
enum ResolutionMode {
  /// From declared types, with the project alone (MVP).
  parseOnly,

  /// With the analyzer's full type resolution (later).
  fullResolution,
}

/// The values of every rule of a [catalog]: immutable.
class AnalysisRules extends Equatable {
  const new _(this.catalog, this._values);

  /// Every rule at its default value.
  factory defaults({List<RuleParameter<Object>> catalog = RuleCatalog.all}) =>
      AnalysisRules._(catalog, {
        for (final rule in catalog) rule.id: rule.defaultValue,
      });

  /// Reads values written by [toJson]. Unknown ids are ignored, missing ids
  /// get their default, and invalid values get their default with a message
  /// added to [warnings].
  factory fromJson(
    Map<String, Object?> json, {
    List<RuleParameter<Object>> catalog = RuleCatalog.all,
    List<String>? warnings,
  }) {
    final values = <String, Object>{};
    for (final rule in catalog) {
      if (!json.containsKey(rule.id)) {
        values[rule.id] = rule.defaultValue;
        continue;
      }
      final value = rule.fromJson(json[rule.id]);
      if (value == null) {
        warnings?.add('Invalid value for ${rule.id}; using the default.');
      }
      values[rule.id] = value ?? rule.defaultValue;
    }
    return AnalysisRules._(catalog, values);
  }

  /// The rule definitions these values belong to.
  final List<RuleParameter<Object>> catalog;

  final Map<String, Object> _values;

  /// The value of rule [id].
  Object operator [](String id) =>
      _values[id] ?? (throw ArgumentError.value(id, 'id', 'unknown rule'));

  /// A copy with rule [id] set to [value].
  ///
  /// Throws an [ArgumentError] for an unknown rule or an invalid value.
  AnalysisRules copyWith(String id, Object value) {
    final rule = catalog.where((r) => r.id == id).firstOrNull;
    if (rule == null) throw ArgumentError.value(id, 'id', 'unknown rule');
    if (!rule.accepts(value)) {
      throw ArgumentError.value(value, 'value', 'invalid for rule $id');
    }
    return AnalysisRules._(catalog, {..._values, id: value});
  }

  /// Every value as JSON, by rule id.
  Map<String, Object?> toJson() => {
    for (final rule in catalog) rule.id: _encode(rule, _values[rule.id]!),
  };

  static Object? _encode<T extends Object>(RuleParameter<T> rule, Object v) =>
      rule.toJson(v as T);

  /// Whether generated files are skipped.
  bool get excludeGenerated => this[RuleIds.excludeGenerated] as bool;

  /// Glob patterns of generated files.
  List<String> get generatedPatterns =>
      (this[RuleIds.generatedPatterns] as List).cast<String>();

  /// Whether tests are skipped.
  bool get excludeTests => this[RuleIds.excludeTests] as bool;

  /// More glob patterns to skip.
  List<String> get extraExcludes =>
      (this[RuleIds.extraExcludes] as List).cast<String>();

  /// Whether calls are links.
  bool get linksCalls => this[RuleIds.linksCalls] as bool;

  /// Whether imports are links.
  bool get linksImports => this[RuleIds.linksImports] as bool;

  /// Whether `implements` clauses are links.
  bool get linksImplements => this[RuleIds.linksImplements] as bool;

  /// Whether `with` clauses are links.
  bool get linksMixins => this[RuleIds.linksMixins] as bool;

  /// What to do with calls on unknown types.
  AmbiguousCallPolicy get ambiguousCalls =>
      AmbiguousCallPolicy.values.byName(this[RuleIds.ambiguousCalls] as String);

  /// Whether external packages are spheres.
  bool get externalPackages => this[RuleIds.externalPackages] as bool;

  /// Whether `dart:` libraries are a package sphere.
  bool get dartSdk => this[RuleIds.dartSdk] as bool;

  /// Whether external superclasses become ghost parents.
  bool get ghostParents => this[RuleIds.ghostParents] as bool;

  /// Whether private declarations are included.
  bool get includePrivate => this[RuleIds.includePrivate] as bool;

  /// Which members become spheres.
  Set<MemberKind> get memberKinds => {
    for (final name in (this[RuleIds.memberKinds] as Set).cast<String>())
      MemberKind.values.byName(name),
  };

  /// The entry file.
  String get entryPoint => this[RuleIds.entryPoint] as String;

  /// How references are resolved.
  ResolutionMode get resolutionMode =>
      ResolutionMode.values.byName(this[RuleIds.resolutionMode] as String);

  @override
  List<Object?> get props => [toJson()];
}
