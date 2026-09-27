# UI library on JVM: checker-resolved receivers, dependency features and transitive Maven (#7378)

`lyric-ui`, `lyric-forms` and `examples/ui-customers` now build and pass
their tests on `--target jvm` as well as `--target dotnet` (D139). The
libraries needed no changes; every failure was in the JVM backend or the
build tooling:

- **Erased receivers (J007).** The type checker records the class of each
  field-access and method-call receiver
  (`SymbolTable.memberRecvClasses`), and the JVM backend checkcasts a
  receiver it sees as `Object` to that class. A match-bound union case
  field such as `props: List[Prop]` also carries its element type into a
  `for` loop.
- **Bare names.** A bare constructor resolves through the file's own
  imports (a `Forms.OutOfRange` was being built as
  `Std.Errors.ParseError.OutOfRange`), a specialised copy of another
  package's generic resolves in its origin package, and `case Info ->` over
  an enum is a case test even when another type is named `Info` (it had
  compiled as a catch-all).
- **Dependencies on JVM.** A dependency compiled into a JVM bundle keeps
  its own `@cfg` features (`EmitProjectRequest.packageFeatures`), transitive
  dependencies are bundled, and `lyric restore` propagates `[maven]` from
  workspace and path dependencies (docs/38 §4), so `lyric-ui` gets Undertow
  through `lyric-web` and `lyric-ws`.

Tests: `lyric-compiler/jvm/erased_receiver_jvm_self_test.l` (5 cases, both
targets) and two new JVM cases in `emitter_project_self_test.l` (a
dependency's own features; a constructor through a selective import). The
emit-containment test there now uses a J009 refusal, since its J007 repro
compiles. The book gains Chapter 31, *User Interfaces*.
