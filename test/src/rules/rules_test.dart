import 'package:code_analysis_engine/code_analysis_engine.dart';
import 'package:test/test.dart';

void main() {
  group(RuleParameter, () {
    const bool = BoolParameter(
      id: 'b',
      title: 'B',
      description: 'd',
      group: RuleGroup.nodes,
      defaultValue: true,
    );
    const choice = EnumParameter(
      id: 'e',
      title: 'E',
      description: 'd',
      group: RuleGroup.links,
      defaultValue: 'a',
      options: [
        RuleOption('a', 'A'),
        RuleOption('z', 'Z', enabled: false, note: 'later'),
      ],
    );
    const set = EnumSetParameter(
      id: 's',
      title: 'S',
      description: 'd',
      group: RuleGroup.nodes,
      defaultValue: {'x'},
      options: [RuleOption('x', 'X'), RuleOption('y', 'Y')],
    );
    const globs = GlobListParameter(
      id: 'g',
      title: 'G',
      description: 'd',
      group: RuleGroup.files,
      defaultValue: [],
    );
    const text = StringParameter(
      id: 't',
      title: 'T',
      description: 'd',
      group: RuleGroup.entry,
      defaultValue: 'x',
    );

    test('$BoolParameter accepts and reads booleans only', () {
      expect(bool.accepts(false), isTrue);
      expect(bool.accepts('false'), isFalse);
      expect(bool.toJson(true), true);
      expect(bool.fromJson(false), false);
      expect(bool.fromJson(1), isNull);
    });

    test('$EnumParameter accepts enabled options only', () {
      expect(choice.accepts('a'), isTrue);
      expect(choice.accepts('z'), isFalse);
      expect(choice.accepts('q'), isFalse);
      expect(choice.toJson('a'), 'a');
      expect(choice.fromJson('a'), 'a');
      expect(choice.fromJson('z'), isNull);
    });

    test('$EnumSetParameter writes options in catalog order', () {
      expect(set.accepts({'x', 'y'}), isTrue);
      expect(set.accepts({'q'}), isFalse);
      expect(set.accepts(['x']), isFalse);
      expect(set.toJson({'y', 'x'}), ['x', 'y']);
      expect(set.fromJson(['y']), {'y'});
      expect(set.fromJson(['q']), isNull);
      expect(set.fromJson([1]), isNull);
      expect(set.fromJson('x'), isNull);
    });

    test('$GlobListParameter validates globs', () {
      expect(GlobListParameter.isValidGlob('**/*.g.dart'), isTrue);
      expect(GlobListParameter.isValidGlob(' '), isFalse);
      expect(GlobListParameter.isValidGlob('[unclosed'), isFalse);
      expect(globs.accepts(['lib/**']), isTrue);
      expect(globs.accepts(['[']), isFalse);
      expect(globs.toJson(['a']), ['a']);
      expect(globs.fromJson(['a']), ['a']);
      expect(globs.fromJson(['[']), isNull);
      expect(globs.fromJson([1]), isNull);
      expect(globs.fromJson('a'), isNull);
    });

    test('$StringParameter refuses blank text', () {
      expect(text.accepts('lib/main.dart'), isTrue);
      expect(text.accepts('  '), isFalse);
      expect(text.toJson('a'), 'a');
      expect(text.fromJson('a'), 'a');
      expect(text.fromJson(''), isNull);
    });

    test('supports value equality', () {
      // Built at runtime: identical constants would skip the comparison.
      final title = ['A'].single;
      expect(RuleOption('a', title), RuleOption('a', title));
      expect(
        EnumSetParameter(
          id: 's',
          title: title,
          description: 'd',
          group: RuleGroup.nodes,
          defaultValue: const {'x'},
          options: const [RuleOption('x', 'X')],
        ).props,
        hasLength(6),
      );
      expect(
        choice,
        const EnumParameter(
          id: 'e',
          title: 'E',
          description: 'd',
          group: RuleGroup.links,
          defaultValue: 'a',
          options: [
            RuleOption('a', 'A'),
            RuleOption('z', 'Z', enabled: false, note: 'later'),
          ],
        ),
      );
      expect(set.props, contains(set.options));
      expect(choice.props, contains(choice.options));
    });
  });

  group(RuleCatalog, () {
    test('has unique ids and valid defaults', () {
      final ids = RuleCatalog.all.map((r) => r.id).toList();

      expect(ids.toSet(), hasLength(ids.length));
      for (final rule in RuleCatalog.all) {
        expect(rule.accepts(rule.defaultValue), isTrue, reason: rule.id);
      }
    });

    test('finds rules by id', () {
      expect(
        RuleCatalog.byId(RuleIds.entryPoint)!.defaultValue,
        'lib/main.dart',
      );
      expect(RuleCatalog.byId('nope'), isNull);
    });

    test('offers full resolution, disabled, with a note', () {
      final mode = RuleCatalog.byId(RuleIds.resolutionMode)! as EnumParameter;
      final full = mode.options.singleWhere((o) => o.value == 'fullResolution');

      expect(full.enabled, isFalse);
      expect(full.note, contains('Coming later'));
    });
  });

  group(AnalysisRules, () {
    test('defaults match architecture §5.3', () {
      final rules = AnalysisRules.defaults();

      expect(rules.excludeGenerated, isTrue);
      expect(rules.generatedPatterns, ['**/*.g.dart']);
      expect(rules.excludeTests, isTrue);
      expect(rules.extraExcludes, isEmpty);
      expect(rules.linksCalls, isTrue);
      expect(rules.linksImports, isFalse);
      expect(rules.linksImplements, isTrue);
      expect(rules.linksMixins, isTrue);
      expect(rules.ambiguousCalls, AmbiguousCallPolicy.uniqueName);
      expect(rules.externalPackages, isTrue);
      expect(rules.dartSdk, isFalse);
      expect(rules.ghostParents, isTrue);
      expect(rules.includePrivate, isTrue);
      expect(rules.memberKinds, MemberKind.values.toSet());
      expect(rules.entryPoint, 'lib/main.dart');
      expect(rules.resolutionMode, ResolutionMode.parseOnly);
    });

    test('round-trips through JSON', () {
      final rules = AnalysisRules.defaults()
          .copyWith(RuleIds.linksImports, true)
          .copyWith(RuleIds.memberKinds, {'method'});

      expect(AnalysisRules.fromJson(rules.toJson()), rules);
      expect(rules.toJson()[RuleIds.memberKinds], ['method']);
    });

    test('reads missing ids as defaults, ignores unknown ids and warns on '
        'invalid values', () {
      final warnings = <String>[];
      final rules = AnalysisRules.fromJson(const {
        RuleIds.dartSdk: true,
        RuleIds.linksCalls: 'yes',
        'unknown.rule': 1,
      }, warnings: warnings);

      expect(rules.dartSdk, isTrue);
      expect(rules.linksCalls, isTrue);
      expect(warnings, ['Invalid value for links.calls; using the default.']);
    });

    test('copyWith refuses unknown rules and invalid values', () {
      final rules = AnalysisRules.defaults();

      expect(() => rules.copyWith('nope', true), throwsArgumentError);
      expect(
        () => rules.copyWith(RuleIds.resolutionMode, 'fullResolution'),
        throwsArgumentError,
      );
      expect(() => rules['nope'], throwsArgumentError);
    });

    test('works with any catalog, so new rules need no UI code', () {
      const catalog = <RuleParameter<Object>>[
        BoolParameter(
          id: 'test.flag',
          title: 'Flag',
          description: 'A rule that only exists in this test.',
          group: RuleGroup.analysis,
          defaultValue: false,
        ),
      ];
      final rules = AnalysisRules.defaults(catalog: catalog)
          .copyWith('test.flag', true);

      expect(rules['test.flag'], isTrue);
      expect(
        AnalysisRules.fromJson(const {'test.flag': true}, catalog: catalog),
        rules,
      );
    });
  });
}
