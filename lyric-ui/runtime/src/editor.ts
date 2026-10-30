// The code editor widget (docs/65 §13.10): a `textArea` with `variant="code"`.
//
// A real <textarea> sits over a highlighted copy of its text, with the text
// itself made transparent, so selection, the caret, IME composition, undo and
// the platform's spell and accessibility behaviour all stay the browser's.
// A gutter shows line numbers. Tab indents (and Escape then Tab leaves the
// field, so keyboard users are not trapped), Shift+Tab outdents and Enter
// keeps the indentation.

import { type Edit, indent, lineCount, newline, outdent } from "./editing.js";
import { tokenize } from "./highlight.js";

export class CodeEditor {
  readonly root: HTMLElement;
  readonly textarea: HTMLTextAreaElement;
  private readonly gutter: HTMLElement;
  private readonly gutterInner: HTMLElement;
  private readonly code: HTMLElement;
  private readonly highlight: HTMLElement;
  private language = "";
  private tabSize = 2;
  private lines = 0;
  // After Escape the next Tab moves focus instead of indenting.
  private leaving = false;
  // Counts the input events the textarea has fired, so an edit applied
  // through `execCommand` (which fires one) is not reported twice.
  private inputs = 0;

  constructor(onUserInput: (value: string) => void) {
    this.root = document.createElement("div");
    this.root.className = "lui-input lui-code";
    this.gutter = document.createElement("div");
    this.gutter.className = "lui-code-gutter";
    this.gutter.setAttribute("aria-hidden", "true");
    this.gutterInner = document.createElement("div");
    this.gutter.appendChild(this.gutterInner);
    const body = document.createElement("div");
    body.className = "lui-code-body";
    this.highlight = document.createElement("pre");
    this.highlight.className = "lui-code-highlight";
    this.highlight.setAttribute("aria-hidden", "true");
    this.code = document.createElement("code");
    this.highlight.appendChild(this.code);
    this.textarea = document.createElement("textarea");
    this.textarea.className = "lui-code-input";
    this.textarea.spellcheck = false;
    this.textarea.setAttribute("wrap", "off");
    this.textarea.setAttribute("autocapitalize", "off");
    this.textarea.setAttribute("autocomplete", "off");
    body.append(this.highlight, this.textarea);
    this.root.append(this.gutter, body);

    this.textarea.addEventListener("input", () => {
      this.inputs += 1;
      this.refresh();
      onUserInput(this.textarea.value);
    });
    this.textarea.addEventListener("scroll", () => this.syncScroll());
    this.textarea.addEventListener("keydown", (e) => this.keydown(e, onUserInput));
    this.textarea.addEventListener("blur", () => {
      this.leaving = false;
    });
    this.refresh();
  }

  get value(): string {
    return this.textarea.value;
  }

  /// Sets the text from the server, leaving the caret alone when it is
  /// already the current text (an echo of the user's own edit).
  setValue(value: string): void {
    if (this.textarea.value !== value) {
      this.textarea.value = value;
      this.refresh();
    }
  }

  setLanguage(language: string): void {
    this.language = language;
    this.root.dataset.language = language;
    this.refresh();
  }

  setTabSize(n: number): void {
    this.tabSize = Number.isInteger(n) && n >= 1 && n <= 16 ? n : 2;
    this.textarea.style.tabSize = String(this.tabSize);
    this.highlight.style.tabSize = String(this.tabSize);
  }

  setLineNumbers(on: boolean): void {
    this.root.classList.toggle("lui-code-nogutter", !on);
  }

  // Redraws the highlight and the gutter from the textarea's text.
  refresh(): void {
    const value = this.textarea.value;
    const frag = document.createDocumentFragment();
    for (const t of tokenize(this.language, value)) {
      if (t.type === "plain") {
        frag.appendChild(document.createTextNode(t.text));
      } else {
        const span = document.createElement("span");
        span.className = `lui-tok-${t.type}`;
        span.textContent = t.text;
        frag.appendChild(span);
      }
    }
    // A final newline needs a character after it, or the last empty line
    // would have no height and the two layers would drift apart.
    frag.appendChild(document.createTextNode("\n"));
    this.code.replaceChildren(frag);
    const n = lineCount(value);
    if (n !== this.lines) {
      this.lines = n;
      const numbers: string[] = [];
      for (let i = 1; i <= n; i++) {
        numbers.push(String(i));
      }
      this.gutterInner.textContent = numbers.join("\n");
    }
    this.syncScroll();
  }

  private syncScroll(): void {
    const x = this.textarea.scrollLeft;
    const y = this.textarea.scrollTop;
    this.highlight.style.transform = `translate(${-x}px, ${-y}px)`;
    this.gutterInner.style.transform = `translateY(${-y}px)`;
  }

  private keydown(e: KeyboardEvent, onUserInput: (value: string) => void): void {
    if (e.key === "Escape") {
      this.leaving = true;
      return;
    }
    if (e.isComposing || e.ctrlKey || e.metaKey || e.altKey || this.textarea.readOnly) {
      return;
    }
    const value = this.textarea.value;
    const a = this.textarea.selectionStart;
    const b = this.textarea.selectionEnd;
    let edit: Edit | null = null;
    if (e.key === "Tab") {
      if (this.leaving) {
        this.leaving = false;
        return;
      }
      edit = e.shiftKey ? outdent(value, a, b, this.tabSize) : indent(value, a, b, this.tabSize);
      if (edit === null) {
        e.preventDefault();
        return;
      }
    } else if (e.key === "Enter" && !e.shiftKey) {
      edit = newline(value, a, b, this.tabSize);
    } else {
      this.leaving = false;
      return;
    }
    e.preventDefault();
    const before = this.inputs;
    this.apply(edit);
    if (this.inputs === before) {
      onUserInput(this.textarea.value);
    }
  }

  // Applies an edit through the browser's editing command, which keeps the
  // undo stack; falls back to a direct replacement.
  private apply(edit: Edit): void {
    const ta = this.textarea;
    ta.setSelectionRange(edit.start, edit.end);
    let done = false;
    try {
      done = document.execCommand("insertText", false, edit.text);
    } catch {
      done = false;
    }
    if (!done) {
      ta.setRangeText(edit.text, edit.start, edit.end, "end");
    }
    ta.setSelectionRange(edit.selStart, edit.selEnd);
    this.refresh();
  }
}
