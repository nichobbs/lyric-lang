//! tir_mono_self_test.l - Lyric.Tir.Mono (docs/70 §7.2, D500): monomorphisation on TIR.
//!
//! Each case builds a small package into TIR, runs `monoBundle`, and checks that the output
//! verifies (`Lyric.Tir.Verify`), that nothing generic is left, and that the instances are the ones
//! the calls and constructions name.
@test_module
package Lyric.TirMonoSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Resolve
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Build
import Lyric.Tir.Verify
import Lyric.Tir.Mono

record Mono {
  r: MonoResult
  built: Int
  total: Int
  diagnostics: Int
  interner: DefPathInterner
}

func monoOf(src: in String): Mono {
  val file = renumberNodeIds(parse(src).file).file
  val cr = check(file)
  val pb = buildPackage(newTyConvCtx(cr.symbols), cr.symbols, file, "App")
  val bundle: List[PackageBuild] = newList()
  bundle.add(pb)
  Mono(
    r = monoBundle(cr.symbols.interner, bundle),
    built = pb.built,
    total = pb.total,
    diagnostics = cr.diagnostics.count,
    interner = cr.symbols.interner
  )
}

func instancesOf(m: in Mono): PackageBuild {
  m.r.pkgs[m.r.pkgs.count - 1]
}

func keyOf(m: in Mono, sym: in SymbolId): String {
  match defPathKeyOf(m.interner, sym) {
    case Some(k) -> k
    case None -> "?"
  }
}

func instanceKeys(m: in Mono): List[String] {
  val ks: List[String] = newList()
  for i in m.r.instances {
    ks.add(keyOf(m, i.inst))
  }
  ks
}

func hasKey(m: in Mono, key: in String): Bool {
  for k in instanceKeys(m) {
    if k == key {
      return true
    }
  }
  false
}

func assertClean(m: in Mono, what: in String): Unit {
  assertEqualInt(m.diagnostics, 0, what + ": the source checks")
  assertEqualInt(m.built, m.total, what + ": every body builds")
  assertEqualInt(m.r.diags.count, 0, what + ": no mono diagnostic" + (if m.r.diags.count > 0 { " " + m.r.diags[0].message } else { "" }))
  val bad = verifyMonoBundle(m.r)
  assertEqualInt(bad.count, 0, what + ": verifies" + (if bad.count > 0 { " " + bad[0] } else { "" }))
  for pb in m.r.pkgs {
    for f in pb.pkg.funcs {
      assertEqualInt(f.typeParams.count, 0, what + ": no origin function is left")
    }
  }
}

func firstFnNamed(pb: in PackageBuild, m: in Mono, name: in String): Option[TFnDecl] {
  for f in pb.pkg.funcs {
    if keyOf(m, f.sym).startsWith("App::" + name + "(") {
      return Some(value = f)
    }
  }
  None
}

func tailOf(f: in TFnDecl): Option[TExpr] {
  match f.body {
    case Some(b) -> match b.kind {
      case XBlock(_, t) -> t
      case _ -> Some(value = b)
    }
    case None -> None
  }
}

test "a origin function called at Int has one instance named by its key" {
  val m = monoOf("package App\nfunc id[T](x: in T): T { x }\nfunc main(): Int { id(3) }\n")
  assertClean(m, "id")
  assertEqualInt(m.r.instances.count, 1, "one instance")
  assertTrue(hasKey(m, "App::id[Int](T)"), "the key puts the arguments before the parameter list")
  assertEqualInt(m.r.pkgs.count, 2, "the package and the instances")
  assertEqualInt(m.r.pkgs[0].pkg.funcs.count, 1, "only main stays in App")
  assertEqualInt(instancesOf(m).pkg.funcs.count, 1, "the instance body is in the instances package")
  assertTrue(instancesOf(m).pkg.name == "Lyric.Mono.Instances", "the synthetic package")
}

test "the call names the instance and has no type arguments" {
  val m = monoOf("package App\nfunc id[T](x: in T): T { x }\nfunc main(): Int { id(3) }\n")
  assertClean(m, "id call")
  match firstFnNamed(m.r.pkgs[0], m, "main") {
    case Some(f) -> match tailOf(f) {
      case Some(t) -> match t.kind {
        case XCall(callee, _) -> match callee {
          case Direct(sym, targs) -> {
            assertEqualInt(targs.count, 0, "no type arguments")
            assertTrue(keyOf(m, sym) == "App::id[Int](T)", "the instance symbol")
          }
          case _ -> assertTrue(false, "a direct callee")
        }
        case _ -> assertTrue(false, "a call")
      }
      case None -> assertTrue(false, "a tail")
    }
    case None -> assertTrue(false, "main")
  }
}

test "two calls at one type share an instance and a second type makes another" {
  val m = monoOf("package App\nfunc id[T](x: in T): T { x }\nfunc a(): Int { id(3) + id(4) }\nfunc b(): String { id(\"s\") }\n")
  assertClean(m, "sharing")
  assertEqualInt(m.r.instances.count, 2, "Int and String")
  assertTrue(hasKey(m, "App::id[Int](T)"), "Int")
  assertTrue(hasKey(m, "App::id[String](T)"), "String")
  assertEqualInt(instancesOf(m).pkg.funcs.count, 2, "two bodies")
}

test "a origin function that calls another instantiates it at its own arguments" {
  val m = monoOf("package App\nfunc id[T](x: in T): T { x }\nfunc twice[T](x: in T): T { id(id(x)) }\nfunc main(): Int { twice(5) }\n")
  assertClean(m, "transitive")
  assertTrue(hasKey(m, "App::twice[Int](T)"), "twice at Int")
  assertTrue(hasKey(m, "App::id[Int](T)"), "id at Int, asked for by twice's body")
  assertEqualInt(m.r.instances.count, 2, "no other instance")
}

test "a origin record applied to arguments is an instance with concrete fields" {
  val m = monoOf("package App\nrecord Box[T] { v: T }\nfunc mk(): Box[Int] { Box(v = 3) }\nfunc get(b: in Box[Int]): Int { b.v }\n")
  assertClean(m, "record")
  assertTrue(hasKey(m, "App::Box[Int]"), "the record instance")
  var found = false
  for en in instancesOf(m).pkg.symbols {
    if keyOf(m, en.sym) == "App::Box[Int]" {
      found = true
      assertEqualInt(en.fields.count, 1, "one field")
      assertTrue(tyEq(en.fields[0].ty, tyInt()), "the field is an Int")
      assertEqualInt(en.typeParamCount, 0, "not origin")
    }
  }
  assertTrue(found, "the instance has an entry")
}

test "a origin union is an instance whose cases are instances in declaration order" {
  val m = monoOf(
    "package App\nunion Opt[T] { case Nope\n case Has(v: T) }\nfunc some(): Opt[Int] { Has(v = 3) }\nfunc none(): Opt[Int] { Nope }\nfunc get(o: in Opt[Int]): Int {\n  match o {\n    case Has(v) -> v\n    case Nope -> 0\n  }\n}\n"
  )
  assertClean(m, "union")
  assertTrue(hasKey(m, "App::Opt[Int]"), "the union instance")
  val inst = instancesOf(m)
  var unionSym = SymbolId(id = 0)
  for i in m.r.instances {
    if keyOf(m, i.inst) == "App::Opt[Int]" {
      unionSym = i.inst
    }
  }
  match mapGet(inst.cases, unionSym.id) {
    case Some(cs) -> {
      assertEqualInt(cs.count, 2, "two cases")
      assertTrue(keyOf(m, cs[0]) == "App::Opt[Int]::Nope", "the first case keeps its place")
      assertTrue(keyOf(m, cs[1]) == "App::Opt[Int]::Has", "the second case")
    }
    case None -> assertTrue(false, "the case list of the instance")
  }
}

test "a origin member of a origin record is instantiated at the receiver's arguments" {
  val m = monoOf(
    "package App\nrecord Box[T] {\n  v: T\n  func get(self: in Box[T]): T { self.v }\n}\nfunc use(b: in Box[Int]): Int { b.get() }\n"
  )
  assertClean(m, "member")
  assertTrue(hasKey(m, "App::Box[Int]"), "the record")
  var member = false
  for k in instanceKeys(m) {
    if k.startsWith("App::Box::get[Int]") {
      member = true
    }
  }
  assertTrue(member, "the method instance")
}

test "a value-generic parameter becomes the length" {
  val m = monoOf(
    "package App\nfunc size[N: Nat](a: in array[N, Int]): Int {\n  N\n}\nfunc main(): Int {\n  val a: array[3, Int] = [1, 2, 3]\n  size(a)\n}\n"
  )
  assertClean(m, "value origin")
  assertTrue(hasKey(m, "App::size[3](array[N,Int])") or hasKey(m, "App::size[3](array[N, Int])"), "the length is the argument")
}

test "a origin function nothing calls leaves no instance" {
  val m = monoOf("package App\nfunc id[T](x: in T): T { x }\nfunc main(): Int { 1 }\n")
  assertClean(m, "uncalled")
  assertEqualInt(m.r.instances.count, 0, "none")
  assertEqualInt(instancesOf(m).pkg.funcs.count, 0, "no body")
}

test "polymorphic recursion ends with a diagnostic" {
  val m = monoOf(
    "package App\nrecord Box[T] { v: T }\nfunc grow[T](x: in T, n: in Int): Int {\n  if n == 0 { 0 } else { grow(Box(v = x), n - 1) }\n}\nfunc main(): Int { grow(1, 3) }\n"
  )
  assertEqualInt(m.diagnostics, 0, "the source checks")
  var seen = false
  for d in m.r.diags {
    if d.code == "M0010" {
      seen = true
    }
  }
  assertTrue(seen, "M0010 names the runaway instantiation")
}
