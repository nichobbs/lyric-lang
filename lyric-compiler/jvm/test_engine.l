//! jvm/test_engine.l — Stage B126: JUnit 5 test-runner adapter infrastructure.
//!
//! Provides the three building blocks described in `docs/32-junit-runner-sketch.md`:
//!
//!   1. `lyricTestAnnotationClass(pool)` — builds the
//!      `lyric/runtime/jvm/LyricTest` annotation-interface ClassFile.
//!      The annotation carries `@Retention(RUNTIME)` and `@Target(METHOD)`,
//!      with three elements: `displayName` (String, default ""),
//!      `sourceFile` (String, default ""), and `sourceLine` (Int, default 0).
//!
//!   2. `TestMethodSlot` — per-test metadata record.
//!
//!   3. `lowerTestModuleClass(className, slots, pool)` — builds a
//!      `public final` test-host ClassFile.  Each slot becomes a
//!      `public static void __lyric_test_<i>()` method annotated with
//!      `@LyricTest(displayName=..., sourceFile=..., sourceLine=...)`.
//!      Method bodies are stubs (single `return` opcode) — the real
//!      bytecode comes from the full Lyric→JVM compilation pipeline (B127+).
//!
//! The `LyricTestEngine` (JUnit 5 `TestEngine` implementation) is deferred
//! to Stage B127; see `docs/32-junit-runner-sketch.md` §5 and §9 Q-J007e.
package Jvm.TestEngine

import Std.Core
import Std.Collections
import Jvm.Kernel
import Jvm.Classfile

// ── TestMethodSlot ────────────────────────────────────────────────────────────
/// Per-test metadata carried into the JVM class emitter.
/// `funcName` is the synthesised method name ("__lyric_test_0", …).
/// `displayName` is the human-readable test title from the `test "…"` declaration.
/// `sourceFile` and `sourceLine` are for IDE navigation.
pub record TestMethodSlot {
  funcName: String
  displayName: String
  sourceFile: String
  sourceLine: Int
  // ── @LyricTest annotation class ───────────────────────────────────────────────
}

/// Build the `lyric/runtime/jvm/LyricTest` annotation-interface ClassFile.
///
/// The generated class corresponds to:
///   @Retention(RetentionPolicy.RUNTIME)
///   @Target(ElementType.METHOD)
///   public @interface LyricTest {
///       String displayName() default "";
///       String sourceFile()  default "";
///       int    sourceLine()  default 0;
///   }
///
/// Pass the same `pool` that will be used in `serializeClassWithPool`.
pub func lyricTestAnnotationClass(pool: in Pool): ClassFile {
  // Class-level annotations: @Retention(RUNTIME) + @Target(METHOD) in a single
  // RuntimeVisibleAnnotations attribute (JVM spec allows at most one per element).
  val classAttrs: List[Attribute] = newList()
  classAttrs.add(makeRetentionAndTargetRVAAttr(pool))

  // Three annotation element methods, each with its AnnotationDefault.
  val dnAttrs: List[Attribute] = newList()
  dnAttrs.add(makeAnnotationDefaultStringAttr(pool))

  val sfAttrs: List[Attribute] = newList()
  sfAttrs.add(makeAnnotationDefaultStringAttr(pool))

  val slAttrs: List[Attribute] = newList()
  slAttrs.add(makeAnnotationDefaultIntAttr(pool))

  val methods: List[MethodInfo] = newList()
  methods.add(makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "displayName", "()Ljava/lang/String;", dnAttrs))
  methods.add(makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "sourceFile", "()Ljava/lang/String;", sfAttrs))
  methods.add(makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "sourceLine", "()I", slAttrs))

  makeAnnotationInterfaceClass("lyric/runtime/jvm/LyricTest", methods, classAttrs)
}

// ── lowerTestModuleClass ──────────────────────────────────────────────────────
// Build one stub test method annotated with @LyricTest.
// The body is a single `return` opcode (0xB1).  The real bytecode
// for the test body is injected by the full Lyric→JVM pipeline (B127+).
func makeStubTestMethod(slot: in TestMethodSlot, pool: in Pool): MethodInfo {
  // RuntimeVisibleAnnotations with @LyricTest — built in classfile.l to avoid
  // List[AnnotationElement] cross-package generic instantiation in this stdlib artifact.
  val annAttr = makeLyricTestRVAAttr(pool, slot.displayName, slot.sourceFile, slot.sourceLine)

  // Minimal Code attribute: `return` only.
  val code: List[Byte] = newList()
  code.add(177u8)
  // 0xB1 = return
  val codeAttr = makeCodeAttr(0, 0, code)

  val attrs: List[Attribute] = newList()
  attrs.add(annAttr)
  attrs.add(codeAttr)

  makeMethodInfo(ACC_PUBLIC + ACC_STATIC, slot.funcName, "()V", attrs)
}

/// Build the test-module ClassFile for `className`.
///
/// Emits `public final class <className>` with one annotated
/// `public static void __lyric_test_<i>()` per slot.  Method bodies
/// are stubs (`return`) until the full Lyric→JVM pipeline (B127+)
/// injects the compiled test code.
///
/// Pass the same `pool` used in `serializeClassWithPool`.
pub func lowerTestModuleClass(className: in String, slots: in List[TestMethodSlot], pool: in Pool): ClassFile {
  val methods: List[MethodInfo] = newList()
  var i = 0
  while i < slots.count {
    methods.add(makeStubTestMethod(slots[i], pool))
    i = i + 1
  }
  // ACC_PUBLIC | ACC_SUPER | ACC_FINAL
  val ifaces: List[String] = newList()
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = className,
    superClass = "java/lang/Object",
    interfaces = ifaces,
    fields = newList(),
    methods = methods,
    attrs = newList()
  )
}
