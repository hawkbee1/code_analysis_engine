import 'dart:async';

import 'package:code_analysis_engine/src/pipeline/containment.dart';
import 'package:code_analysis_engine/src/pipeline/file_collector.dart';
import 'package:code_analysis_engine/src/pipeline/parsed_library.dart';
import 'package:code_analysis_engine/src/pipeline/symbol_table.dart';
import 'package:code_analysis_engine/src/pipeline/uri_resolver.dart';
import 'package:code_analysis_engine/src/resolve/link_builder.dart';
import 'package:code_analysis_engine/src/resolve/reference_collector.dart';
import 'package:code_analysis_engine/src/resolve/reference_resolver.dart';
import 'package:code_analysis_engine/src/resolve/resolvers.dart';
import 'package:code_analysis_engine/src/rules/analysis_rules.dart';
import 'package:code_graph/code_graph.dart';
import 'package:code_source_client/code_source_client.dart';
import 'package:equatable/equatable.dart';

/// Lets the caller stop an analysis.
class CancelToken {
  bool _cancelled = false;

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Asks the analysis to stop as soon as possible.
  void cancel() => _cancelled = true;
}

/// What the engine is doing.
enum AnalysisStage {
  /// Picking files and packages.
  collecting,

  /// Parsing files.
  parsing,

  /// Reading declarations and namespaces.
  declarations,

  /// Building nodes and the containment tree.
  containment,

  /// Resolving references into links.
  links,
}

/// Something that happened during an analysis.
sealed class AnalysisEvent extends Equatable {
  const new();
}

/// Progress: [done] of [total] in [stage]; [currentPath] is the file being
/// handled, if any.
class AnalysisProgress extends AnalysisEvent {
  /// Creates a progress event.
  const new(this.stage, {this.done = 0, this.total = 0, this.currentPath});

  /// What the engine is doing.
  final AnalysisStage stage;

  /// Items done.
  final int done;

  /// Items in this stage.
  final int total;

  /// The file being handled.
  final String? currentPath;

  @override
  List<Object?> get props => [stage, done, total, currentPath];
}

/// The analysis finished.
class AnalysisDone extends AnalysisEvent {
  /// Creates the final success event.
  const new(this.graph, {this.callSites = const CallSiteStats()});

  /// The result.
  final CodeGraph graph;

  /// How the call sites were resolved (quality of parse-only resolution).
  final CallSiteStats callSites;

  @override
  List<Object?> get props => [graph, callSites];
}

/// The analysis stopped: [error] is an [AnalysisCancelled] or a bug.
class AnalysisFailed extends AnalysisEvent {
  /// Creates the final failure event.
  const new(this.error, [this.stackTrace]);

  /// What went wrong.
  final Object error;

  /// Where, for bugs.
  final StackTrace? stackTrace;

  @override
  List<Object?> get props => [error];
}

/// The analysis was cancelled through its [CancelToken].
class AnalysisCancelled extends Equatable implements Exception {
  /// Creates the error.
  const new();

  @override
  List<Object?> get props => [];
}

/// Turns a [SourceSnapshot] into a [CodeGraph] (architecture §5).
///
/// Pure Dart and web-compatible: it only uses the analyzer's parser.
class CodeAnalysisEngine {
  /// Creates an engine; [clock] dates the result (tests fix it) and
  /// [annotators] run on the finished graph (none in the MVP).
  ///
  /// With [yieldToEventLoop], the engine lets the event loop run after each
  /// progress event: the UI stays responsive when it runs on the UI thread
  /// (web), and cancel messages reach it promptly in an isolate.
  new({
    DateTime Function()? clock,
    this.generator = defaultGenerator,
    this.annotators = const [],
    this.yieldToEventLoop = false,
  }) : _clock = clock ?? DateTime.now;

  /// Generator string written in every graph.
  static const defaultGenerator = 'dart_code_3d engine 0.1.0';

  /// Progress is reported every this many files.
  static const progressInterval = 25;

  /// Generator string written in every graph.
  final String generator;

  /// Run in order on the finished graph (future design-pattern detectors).
  final List<GraphAnnotator> annotators;

  /// Whether to let the event loop run after each progress event.
  final bool yieldToEventLoop;

  Future<void> _breathe() async {
    if (yieldToEventLoop) await Future<void>.delayed(Duration.zero);
  }

  final DateTime Function() _clock;

  /// Analyzes [snapshot] with [rules].
  ///
  /// Emits [AnalysisProgress] events, then one [AnalysisDone] or
  /// [AnalysisFailed]. [cancel] is checked between files.
  Stream<AnalysisEvent> analyze(
    SourceSnapshot snapshot,
    AnalysisRules rules, {
    CancelToken? cancel,
  }) async* {
    final token = cancel ?? CancelToken();
    final watch = Stopwatch()..start();
    try {
      yield const AnalysisProgress(AnalysisStage.collecting);
      final files = await FileCollector(rules).collect(snapshot);
      final resolver = UriResolver(files.packages);

      final parsed = <ParsedFile>[];
      var parseErrors = 0;
      final total = files.dartFiles.length;
      for (final (index, path) in files.dartFiles.indexed) {
        if (token.isCancelled) throw const AnalysisCancelled();
        if (index % progressInterval == 0) {
          yield AnalysisProgress(
            AnalysisStage.parsing,
            done: index,
            total: total,
            currentPath: path,
          );
          await _breathe();
        }
        final file = ParsedFile.parse(path, await snapshot.readAsString(path));
        if (file == null) {
          parseErrors++;
        } else {
          parsed.add(file);
        }
      }
      if (token.isCancelled) throw const AnalysisCancelled();

      yield AnalysisProgress(AnalysisStage.declarations, total: parsed.length);
      final libraries = groupLibraries(parsed, resolver);
      final symbols = SymbolTable.build(libraries, resolver);

      yield AnalysisProgress(AnalysisStage.containment, total: parsed.length);
      final containment = buildContainment(
        libraries: libraries,
        symbols: symbols,
        files: files,
        rules: rules,
      );

      final links = LinkBuilder(containment.nodes);
      final context = ResolverContext(
        symbols: symbols,
        nodeIdsByAst: containment.nodeIdsByAst,
        rules: rules,
      );
      var skippedTopLevel = 0;
      if (rules.linksCalls) {
        final collector = ReferenceCollector(
          resolver: resolverFor(rules.resolutionMode),
          context: context,
          sink: links.addReference,
        );
        for (final (index, library) in libraries.indexed) {
          if (token.isCancelled) throw const AnalysisCancelled();
          if (index % progressInterval == 0) {
            yield AnalysisProgress(
              AnalysisStage.links,
              done: index,
              total: libraries.length,
              currentPath: library.path,
            );
            await _breathe();
          }
          collector.collect(library);
        }
        skippedTopLevel = collector.skippedTopLevelSites;
      }
      links
        ..addExternalSuperclasses(containment)
        ..addTypeRelations(symbols, {
          for (final library in symbols.libraries.values)
            for (final declaration in library.declarations.values)
              declaration: context.nodeIdOf(declaration),
        }, rules);
      if (rules.linksImports) links.addImports(libraries, symbols);
      final linkList = links.build();

      var graph = CodeGraph(
        project: ProjectInfo(
          generator: generator,
          source: snapshot.descriptor,
          createdAt: _clock().toUtc(),
          rules: rules.toJson(),
          entryNodeId: containment.entryNodeId,
          stats: GraphStats(
            files: total,
            parseErrors: parseErrors,
            nodes: containment.nodes.length,
            links: linkList.length,
            durationMs: watch.elapsedMilliseconds,
          ),
        ),
        nodes: containment.nodes,
        links: linkList,
      );
      for (final annotator in annotators) {
        graph = annotator.annotate(graph);
      }
      yield AnalysisDone(
        graph,
        callSites: links.stats(skippedTopLevel: skippedTopLevel),
      );
    } on AnalysisCancelled catch (e) {
      yield AnalysisFailed(e);
      // A bug must not end the stream silently: report it with its trace.
    } on Object catch (e, stackTrace) {
      yield AnalysisFailed(e, stackTrace);
    }
  }
}
