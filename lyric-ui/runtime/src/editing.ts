// Pure text edits for the code editor (docs/65 §13.10): what Tab, Shift+Tab
// and Enter do to a value and a selection. Each function returns an `Edit`
// that replaces `[start, end)` of the value with `text` and then selects
// `[selStart, selEnd)` of the result, so the DOM layer can apply it through
// the browser's own editing command and keep the undo stack.

export interface Edit {
  start: number;
  end: number;
  text: string;
  selStart: number;
  selEnd: number;
}

const openers = "{([";
const closers = "})]";

function lineStart(value: string, at: number): number {
  return value.lastIndexOf("\n", at - 1) + 1;
}

function lineEnd(value: string, at: number): number {
  const e = value.indexOf("\n", at);
  return e < 0 ? value.length : e;
}

function leadingSpaces(line: string): number {
  let n = 0;
  while (n < line.length && (line[n] === " " || line[n] === "\t")) {
    n += 1;
  }
  return n;
}

/// Tab with no selection inserts spaces up to the next tab stop; with a
/// selection spanning lines it indents every line the selection touches.
export function indent(value: string, selStart: number, selEnd: number, tabSize: number): Edit {
  const crossesLines = value.slice(selStart, selEnd).includes("\n");
  if (selStart === selEnd || !crossesLines) {
    const column = selStart - lineStart(value, selStart);
    const pad = " ".repeat(tabSize - (column % tabSize));
    return { start: selStart, end: selEnd, text: pad, selStart: selStart + pad.length, selEnd: selStart + pad.length };
  }
  const first = lineStart(value, selStart);
  // A selection that ends at the start of a line does not touch that line.
  const last = selEnd > selStart && value[selEnd - 1] === "\n" ? selEnd - 1 : selEnd;
  const block = value.slice(first, lineEnd(value, last));
  const lines = block.split("\n");
  const pad = " ".repeat(tabSize);
  const text = lines.map((l) => pad + l).join("\n");
  return {
    start: first,
    end: first + block.length,
    text,
    selStart: selStart + pad.length,
    selEnd: selEnd + pad.length * lines.length,
  };
}

/// Shift+Tab removes up to one tab stop of leading spaces (or one tab) from
/// every line the selection touches. `null` when there is nothing to remove.
export function outdent(value: string, selStart: number, selEnd: number, tabSize: number): Edit | null {
  const first = lineStart(value, selStart);
  const last = selEnd > selStart && value[selEnd - 1] === "\n" ? selEnd - 1 : selEnd;
  const block = value.slice(first, lineEnd(value, last));
  const lines = block.split("\n");
  const removed: number[] = [];
  const kept = lines.map((l) => {
    let n = 0;
    if (l[0] === "\t") {
      n = 1;
    } else {
      while (n < tabSize && l[n] === " ") {
        n += 1;
      }
    }
    removed.push(n);
    return l.slice(n);
  });
  const total = removed.reduce((a, b) => a + b, 0);
  if (total === 0) {
    return null;
  }
  const firstRemoved = removed[0]!;
  const startInLine = selStart - first;
  return {
    start: first,
    end: first + block.length,
    text: kept.join("\n"),
    selStart: selStart - Math.min(firstRemoved, startInLine),
    selEnd: Math.max(selStart === selEnd ? selStart - Math.min(firstRemoved, startInLine) : selEnd - total, first),
  };
}

/// Enter keeps the current line's indentation. After an opening bracket it
/// indents one more level, and between a bracket pair it opens a blank,
/// indented line and leaves the closing bracket on the line after.
export function newline(value: string, selStart: number, selEnd: number, tabSize: number): Edit {
  const ls = lineStart(value, selStart);
  const before = value.slice(ls, selStart);
  // Copy the leading whitespace verbatim, so tabs stay tabs.
  const lead = before.slice(0, leadingSpaces(before));
  const prev = before.trimEnd().slice(-1);
  const next = value[selEnd] ?? "";
  const opens = prev !== "" && openers.includes(prev);
  if (opens && next !== "" && closers.includes(next) && closers.indexOf(next) === openers.indexOf(prev)) {
    const inner = lead + " ".repeat(tabSize);
    const text = "\n" + inner + "\n" + lead;
    return { start: selStart, end: selEnd, text, selStart: selStart + 1 + inner.length, selEnd: selStart + 1 + inner.length };
  }
  const extra = opens ? " ".repeat(tabSize) : "";
  const text = "\n" + lead + extra;
  return { start: selStart, end: selEnd, text, selStart: selStart + text.length, selEnd: selStart + text.length };
}

/// The number of lines in `value` (a trailing newline starts a new, empty line).
export function lineCount(value: string): number {
  let n = 1;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "\n") {
      n += 1;
    }
  }
  return n;
}
