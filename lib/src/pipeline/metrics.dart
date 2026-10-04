/// Counts lines of code: non-blank lines that are not only comments.
///
/// Lines are counted between [startLine] and [endLine] (1-based,
/// inclusive) of [lines]. Comment detection is lexical and approximate: a
/// `/*` inside a string literal is taken for a comment start.
int linesOfCode(List<String> lines, int startLine, int endLine) {
  var count = 0;
  var inBlock = false;
  for (var n = startLine; n <= endLine && n <= lines.length; n++) {
    final line = lines[n - 1];
    var hasCode = false;
    var i = 0;
    while (i < line.length) {
      if (inBlock) {
        final end = line.indexOf('*/', i);
        if (end == -1) break;
        inBlock = false;
        i = end + 2;
        continue;
      }
      final char = line[i];
      if (char == ' ' || char == '\t' || char == '\r') {
        i++;
      } else if (line.startsWith('//', i)) {
        break;
      } else if (line.startsWith('/*', i)) {
        inBlock = true;
        i += 2;
      } else {
        hasCode = true;
        // Keep scanning only for a block comment that stays open.
        final open = line.indexOf('/*', i);
        if (open != -1 && line.indexOf('*/', open + 2) == -1) inBlock = true;
        break;
      }
    }
    if (hasCode) count++;
  }
  return count;
}
