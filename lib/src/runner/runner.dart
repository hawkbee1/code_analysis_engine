// The platform's default runner: an isolate on native platforms, inline on
// the web (no isolates there).
export 'runner_web.dart' if (dart.library.io) 'runner_io.dart';
