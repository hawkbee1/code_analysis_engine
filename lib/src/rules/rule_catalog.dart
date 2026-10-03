import 'package:code_analysis_engine/src/rules/rule_parameter.dart';

/// Ids of the MVP rules (architecture §5.3). They are stored in settings and
/// in code map files: never rename one.
abstract final class RuleIds {
  /// Skip generated files.
  static const excludeGenerated = 'files.exclude_generated';

  /// What counts as generated.
  static const generatedPatterns = 'files.generated_patterns';

  /// Skip tests.
  static const excludeTests = 'files.exclude_tests';

  /// More files to skip.
  static const extraExcludes = 'files.extra_excludes';

  /// Calls are links.
  static const linksCalls = 'links.calls';

  /// Imports are links.
  static const linksImports = 'links.imports';

  /// `implements` clauses are links.
  static const linksImplements = 'links.implements';

  /// `with` clauses are links.
  static const linksMixins = 'links.mixins';

  /// What to do with calls whose receiver type is unknown.
  static const ambiguousCalls = 'links.ambiguous_calls';

  /// Show external package spheres.
  static const externalPackages = 'nodes.external_packages';

  /// Show `dart:` libraries as a package sphere.
  static const dartSdk = 'nodes.dart_sdk';

  /// External superclasses become ghost parent spheres.
  static const ghostParents = 'nodes.ghost_parents';

  /// Include private declarations.
  static const includePrivate = 'nodes.private';

  /// Which members become spheres.
  static const memberKinds = 'nodes.member_kinds';

  /// The entry file.
  static const entryPoint = 'entry.point';

  /// Parse only, or full type resolution.
  static const resolutionMode = 'analysis.resolution_mode';
}

/// Every rule, in display order.
abstract final class RuleCatalog {
  /// The rule definitions.
  static const List<RuleParameter<Object>> all = [
    BoolParameter(
      id: RuleIds.excludeGenerated,
      title: 'Skip generated files',
      description: 'Do not analyze files matching the generated patterns.',
      group: RuleGroup.files,
      defaultValue: true,
    ),
    GlobListParameter(
      id: RuleIds.generatedPatterns,
      title: 'Generated file patterns',
      description:
          'Glob patterns of generated files, e.g. **/*.g.dart or '
          '**/*.freezed.dart.',
      group: RuleGroup.files,
      defaultValue: ['**/*.g.dart'],
    ),
    BoolParameter(
      id: RuleIds.excludeTests,
      title: 'Skip tests',
      description:
          'Do not analyze test/, integration_test/, test_driver/ and '
          '*_test.dart files.',
      group: RuleGroup.files,
      defaultValue: true,
    ),
    GlobListParameter(
      id: RuleIds.extraExcludes,
      title: 'Other files to skip',
      description:
          'More glob patterns to skip. Hidden folders and build/ are always '
          'skipped.',
      group: RuleGroup.files,
      defaultValue: [],
    ),
    BoolParameter(
      id: RuleIds.linksCalls,
      title: 'Calls',
      description: 'Function and method calls are links.',
      group: RuleGroup.links,
      defaultValue: true,
    ),
    BoolParameter(
      id: RuleIds.linksImports,
      title: 'Imports',
      description:
          'Imports are links, between the largest declarations of the two '
          'files (or the package sphere).',
      group: RuleGroup.links,
      defaultValue: false,
    ),
    BoolParameter(
      id: RuleIds.linksImplements,
      title: 'Implements',
      description: '`implements` clauses are links.',
      group: RuleGroup.links,
      defaultValue: true,
    ),
    BoolParameter(
      id: RuleIds.linksMixins,
      title: 'Mixins',
      description: '`with` clauses are links.',
      group: RuleGroup.links,
      defaultValue: true,
    ),
    EnumParameter(
      id: RuleIds.ambiguousCalls,
      title: 'Calls on unknown types',
      description:
          'When the type of the receiver is unknown: drop the call, link it '
          'only if one project member has that name, or link every '
          'candidate.',
      group: RuleGroup.links,
      defaultValue: 'uniqueName',
      options: [
        RuleOption('skip', 'Drop them'),
        RuleOption('uniqueName', 'Link when the name is unique'),
        RuleOption('all', 'Link every candidate'),
      ],
    ),
    BoolParameter(
      id: RuleIds.externalPackages,
      title: 'External packages',
      description:
          'Show the packages the code uses as spheres you cannot enter.',
      group: RuleGroup.nodes,
      defaultValue: true,
    ),
    BoolParameter(
      id: RuleIds.dartSdk,
      title: 'Dart SDK',
      description: 'Show dart: libraries as a package sphere named dart.',
      group: RuleGroup.nodes,
      defaultValue: false,
    ),
    BoolParameter(
      id: RuleIds.ghostParents,
      title: 'Ghost parents',
      description:
          'A class extending an external class (e.g. StatelessWidget) goes '
          'inside a ghost sphere named after it; otherwise it stays at the '
          'top level with an extends link.',
      group: RuleGroup.nodes,
      defaultValue: true,
    ),
    BoolParameter(
      id: RuleIds.includePrivate,
      title: 'Private declarations',
      description: 'Include declarations whose name starts with _.',
      group: RuleGroup.nodes,
      defaultValue: true,
    ),
    EnumSetParameter(
      id: RuleIds.memberKinds,
      title: 'Members shown',
      description: 'Which class members become spheres inside their class.',
      group: RuleGroup.nodes,
      defaultValue: {'method', 'constructor', 'getter', 'setter'},
      options: [
        RuleOption('method', 'Methods'),
        RuleOption('constructor', 'Constructors'),
        RuleOption('getter', 'Getters'),
        RuleOption('setter', 'Setters'),
      ],
    ),
    StringParameter(
      id: RuleIds.entryPoint,
      title: 'Entry file',
      description:
          'Where the camera starts: the main() of this file. Falls back to '
          'lib/main_*.dart, any main() under lib/, then the largest '
          'declaration.',
      group: RuleGroup.entry,
      defaultValue: 'lib/main.dart',
    ),
    EnumParameter(
      id: RuleIds.resolutionMode,
      title: 'Analysis precision',
      description:
          'Parse only resolves calls from declared types with the project '
          'alone, the same on every device. Full resolution will need the '
          'Dart SDK and every dependency: slower and heavy.',
      group: RuleGroup.analysis,
      defaultValue: 'parseOnly',
      options: [
        RuleOption('parseOnly', 'Parse only'),
        RuleOption(
          'fullResolution',
          'Full resolution',
          enabled: false,
          note:
              'Coming later. It downloads every dependency and needs much '
              'more time and memory, especially on phones and in browsers.',
        ),
      ],
    ),
  ];

  /// The definition of the rule [id], or null.
  static RuleParameter<Object>? byId(String id) {
    for (final rule in all) {
      if (rule.id == id) return rule;
    }
    return null;
  }
}
