// Syntax highlighting for the code editor (docs/65 §13.10): a tokenizer per
// language, kept small and dependency-free. A token's `type` is a CSS class
// suffix (`lui-tok-<type>`); text that is none of these is `plain`.
// Tokenizing is lossless: concatenating the tokens' text gives back the input.

export type TokenType = "plain" | "keyword" | "type" | "string" | "comment" | "number" | "punct" | "literal" | "key";

export interface Token {
  type: TokenType;
  text: string;
}

const lyricKeywords = new Set([
  "package", "import", "pub", "func", "val", "var", "record", "union", "enum", "case", "match", "if", "else",
  "while", "for", "in", "return", "break", "continue", "interface", "impl", "type", "alias", "opaque", "protected",
  "async", "await", "spawn", "scope", "test", "requires", "ensures", "invariant", "wire", "config", "aspect",
  "extern", "defer", "try", "catch", "and", "or", "not", "out", "inout", "self", "when", "from", "as",
]);
const lyricLiterals = new Set(["true", "false", "None", "Some", "Ok", "Err"]);

export const languages = ["plain", "lyric", "json"] as const;

function isDigit(c: string): boolean {
  return c >= "0" && c <= "9";
}
function isIdentStart(c: string): boolean {
  return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "_";
}
function isIdentPart(c: string): boolean {
  return isIdentStart(c) || isDigit(c);
}

// Appends to `out`, merging with a preceding token of the same type.
function push(out: Token[], type: TokenType, text: string): void {
  if (text.length === 0) {
    return;
  }
  const last = out[out.length - 1];
  if (last && last.type === type) {
    last.text += text;
  } else {
    out.push({ type, text });
  }
}

// A number literal starting at `i`: digits, an optional fraction and
// exponent, hex/binary/octal prefixes, `_` separators and a type suffix
// (`10i64`, `0.5f32`). Returns the end index.
function numberEnd(s: string, i: number): number {
  let j = i;
  if (s[j] === "0" && (s[j + 1] === "x" || s[j + 1] === "X" || s[j + 1] === "b" || s[j + 1] === "o")) {
    j += 2;
    while (j < s.length && (isIdentPart(s[j]!))) {
      j += 1;
    }
    return j;
  }
  while (j < s.length && (isDigit(s[j]!) || s[j] === "_")) {
    j += 1;
  }
  if (s[j] === "." && isDigit(s[j + 1] ?? "")) {
    j += 1;
    while (j < s.length && (isDigit(s[j]!) || s[j] === "_")) {
      j += 1;
    }
  }
  if ((s[j] === "e" || s[j] === "E") && (isDigit(s[j + 1] ?? "") || ((s[j + 1] === "+" || s[j + 1] === "-") && isDigit(s[j + 2] ?? "")))) {
    j += 2;
    while (j < s.length && isDigit(s[j]!)) {
      j += 1;
    }
  }
  while (j < s.length && isIdentPart(s[j]!)) {
    j += 1;
  }
  return j;
}

// A double-quoted string starting at `i` (a backslash escapes the next
// character); an unterminated string ends at the end of its line.
function stringEnd(s: string, i: number): number {
  let j = i + 1;
  while (j < s.length && s[j] !== "\n") {
    if (s[j] === "\\") {
      j += 2;
      continue;
    }
    if (s[j] === '"') {
      return j + 1;
    }
    j += 1;
  }
  return Math.min(j, s.length);
}

function lyric(s: string): Token[] {
  const out: Token[] = [];
  let i = 0;
  while (i < s.length) {
    const c = s[i]!;
    if (c === "/" && s[i + 1] === "/") {
      const e = s.indexOf("\n", i);
      const end = e < 0 ? s.length : e;
      push(out, "comment", s.slice(i, end));
      i = end;
    } else if (c === "/" && s[i + 1] === "*") {
      // Block comments nest.
      let depth = 1;
      let j = i + 2;
      while (j < s.length && depth > 0) {
        if (s[j] === "/" && s[j + 1] === "*") {
          depth += 1;
          j += 2;
        } else if (s[j] === "*" && s[j + 1] === "/") {
          depth -= 1;
          j += 2;
        } else {
          j += 1;
        }
      }
      push(out, "comment", s.slice(i, j));
      i = j;
    } else if (c === '"') {
      const e = stringEnd(s, i);
      push(out, "string", s.slice(i, e));
      i = e;
    } else if (isDigit(c)) {
      const e = numberEnd(s, i);
      push(out, "number", s.slice(i, e));
      i = e;
    } else if (isIdentStart(c)) {
      let j = i + 1;
      while (j < s.length && isIdentPart(s[j]!)) {
        j += 1;
      }
      const word = s.slice(i, j);
      const type: TokenType = lyricKeywords.has(word)
        ? "keyword"
        : lyricLiterals.has(word)
          ? "literal"
          : c >= "A" && c <= "Z"
            ? "type"
            : "plain";
      push(out, type, word);
      i = j;
    } else if ("{}()[]<>=+-*/%!&|^~?:;,.@".includes(c)) {
      push(out, "punct", c);
      i += 1;
    } else {
      push(out, "plain", c);
      i += 1;
    }
  }
  return out;
}

function json(s: string): Token[] {
  const out: Token[] = [];
  let i = 0;
  while (i < s.length) {
    const c = s[i]!;
    if (c === '"') {
      const e = stringEnd(s, i);
      // A string followed (after spaces) by a colon is an object key.
      let k = e;
      while (k < s.length && (s[k] === " " || s[k] === "\t")) {
        k += 1;
      }
      push(out, s[k] === ":" ? "key" : "string", s.slice(i, e));
      i = e;
    } else if (isDigit(c) || (c === "-" && isDigit(s[i + 1] ?? ""))) {
      const e = numberEnd(s, i + 1);
      push(out, "number", s.slice(i, e));
      i = e;
    } else if (isIdentStart(c)) {
      let j = i + 1;
      while (j < s.length && isIdentPart(s[j]!)) {
        j += 1;
      }
      const word = s.slice(i, j);
      push(out, word === "true" || word === "false" || word === "null" ? "literal" : "plain", word);
      i = j;
    } else if ("{}[],:".includes(c)) {
      push(out, "punct", c);
      i += 1;
    } else {
      push(out, "plain", c);
      i += 1;
    }
  }
  return out;
}

/// Splits `text` into tokens for `language` (`lyric`, `json`; anything else
/// is plain text).
export function tokenize(language: string, text: string): Token[] {
  switch (language) {
    case "lyric":
      return lyric(text);
    case "json":
      return json(text);
    default:
      return text.length === 0 ? [] : [{ type: "plain", text }];
  }
}
