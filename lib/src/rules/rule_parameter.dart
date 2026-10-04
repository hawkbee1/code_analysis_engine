import 'package:equatable/equatable.dart';
import 'package:glob/glob.dart';

/// The settings section a rule is shown in.
enum RuleGroup {
  /// Which files are analyzed.
  files,

  /// Which links are created.
  links,

  /// Which nodes are created.
  nodes,

  /// Where the camera starts.
  entry,

  /// How the code is analyzed.
  analysis,
}

/// One choice of an [EnumParameter] or [EnumSetParameter].
class RuleOption extends Equatable {
  /// Creates an option; a disabled option is shown greyed out with [note].
  const new(this.value, this.title, {this.enabled = true, this.note});

  /// The stored value.
  final String value;

  /// Label shown to the user.
  final String title;

  /// Whether the user can pick it now.
  final bool enabled;

  /// Why it is disabled, or extra information.
  final String? note;

  @override
  List<Object?> get props => [value, title, enabled, note];
}

/// A typed, described, persisted engine setting.
///
/// The settings screen renders rules generically from these definitions:
/// adding a rule to `RuleCatalog` needs no UI code.
sealed class RuleParameter<T> extends Equatable {
  const new({
    required this.id,
    required this.title,
    required this.description,
    required this.group,
    required this.defaultValue,
  });

  /// Stable id, stored in settings and in code map files.
  final String id;

  /// Label shown to the user.
  final String title;

  /// What the rule does.
  final String description;

  /// Settings section.
  final RuleGroup group;

  /// Value when the user changed nothing.
  final T defaultValue;

  /// Whether [value] is a valid value of this rule.
  bool accepts(Object? value);

  /// [value] as JSON.
  Object? toJson(T value);

  /// Reads a JSON value; returns null when it is not a valid value.
  T? fromJson(Object? json);

  @override
  List<Object?> get props => [id, title, description, group, defaultValue];
}

/// An on/off rule.
class BoolParameter extends RuleParameter<bool> {
  /// Creates the rule.
  const new({
    required super.id,
    required super.title,
    required super.description,
    required super.group,
    required super.defaultValue,
  });

  @override
  bool accepts(Object? value) => value is bool;

  @override
  Object? toJson(bool value) => value;

  @override
  bool? fromJson(Object? json) => json is bool ? json : null;
}

/// A rule with one value among [options].
class EnumParameter extends RuleParameter<String> {
  /// Creates the rule.
  const new({
    required super.id,
    required super.title,
    required super.description,
    required super.group,
    required super.defaultValue,
    required this.options,
  });

  /// The choices.
  final List<RuleOption> options;

  @override
  bool accepts(Object? value) =>
      value is String && options.any((o) => o.value == value && o.enabled);

  @override
  Object? toJson(String value) => value;

  @override
  String? fromJson(Object? json) => accepts(json) ? json! as String : null;

  @override
  List<Object?> get props => [...super.props, options];
}

/// A rule with any subset of [options].
class EnumSetParameter extends RuleParameter<Set<String>> {
  /// Creates the rule.
  const new({
    required super.id,
    required super.title,
    required super.description,
    required super.group,
    required super.defaultValue,
    required this.options,
  });

  /// The choices.
  final List<RuleOption> options;

  @override
  bool accepts(Object? value) =>
      value is Set<String> &&
      value.every((v) => options.any((o) => o.value == v && o.enabled));

  @override
  Object? toJson(Set<String> value) => [
    for (final o in options)
      if (value.contains(o.value)) o.value,
  ];

  @override
  Set<String>? fromJson(Object? json) {
    if (json is! List || json.any((v) => v is! String)) return null;
    final set = json.cast<String>().toSet();
    return accepts(set) ? set : null;
  }

  @override
  List<Object?> get props => [...super.props, options];
}

/// A rule holding glob patterns (`**/*.g.dart`), matched against paths
/// relative to the analyzed root with `/` separators.
class GlobListParameter extends RuleParameter<List<String>> {
  /// Creates the rule.
  const new({
    required super.id,
    required super.title,
    required super.description,
    required super.group,
    required super.defaultValue,
  });

  /// Whether [pattern] is a valid glob.
  static bool isValidGlob(String pattern) {
    if (pattern.trim().isEmpty) return false;
    try {
      Glob(pattern);
      return true;
    } on FormatException {
      return false;
    }
  }

  @override
  bool accepts(Object? value) =>
      value is List<String> && value.every(isValidGlob);

  @override
  Object? toJson(List<String> value) => List<String>.of(value);

  @override
  List<String>? fromJson(Object? json) {
    if (json is! List || json.any((v) => v is! String)) return null;
    final list = json.cast<String>().toList();
    return accepts(list) ? list : null;
  }
}

/// A free text rule.
class StringParameter extends RuleParameter<String> {
  /// Creates the rule.
  const new({
    required super.id,
    required super.title,
    required super.description,
    required super.group,
    required super.defaultValue,
  });

  @override
  bool accepts(Object? value) => value is String && value.trim().isNotEmpty;

  @override
  Object? toJson(String value) => value;

  @override
  String? fromJson(Object? json) => accepts(json) ? json! as String : null;
}
