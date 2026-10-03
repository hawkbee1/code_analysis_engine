import 'package:code_analysis_engine/src/resolve/declared_type_resolver.dart';
import 'package:code_analysis_engine/src/resolve/reference_resolver.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';

/// The resolver of [mode] (architecture §5.2). The only place that knows
/// the concrete resolvers.
///
/// `fullResolution` is not available yet (the rule refuses it): it throws
/// an [UnsupportedError].
ReferenceResolver resolverFor(ResolutionMode mode) => switch (mode) {
  ResolutionMode.parseOnly => const DeclaredTypeResolver(),
  ResolutionMode.fullResolution => throw UnsupportedError(
    'Full resolution is not available yet (docs/dart_code_3d/future.md).',
  ),
};
