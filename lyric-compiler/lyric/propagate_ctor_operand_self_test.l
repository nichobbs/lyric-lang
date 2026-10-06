//! propagate_ctor_operand_self_test.l — runtime regression test for the `?`
//! operator applied to a value built at an instantiation of its own (#8181),
//! on every target.
//!
//! `Lyric.Propagate` lowers `e?` to a match on `e` that re-wraps a failure as
//! the enclosing function's.  A bare `Ok(value = "bb")` operand in a
//! `Result[Int, String]` function is a `Result[String, String]`, but the
//! dotnet backend built it at the function's own `Result<int, string>` and
//! the match read the `string` payload as an `int`: the CLR rejected the
//! method with `InvalidProgramException`.  The type checker now records such
//! an operand's type, so it is bound to a local annotated with that type
//! before the lowering: its success type is its own, or, for an operand that
//! fixes none (`Err(error = x)?`, `None?`), the type the position consuming
//! the value expects (a binding's annotation, a parameter, a record field, the
//! other operand of a binary operator, the branches of an `if`/`match`), and
//! its error type is the enclosing function's.  The dotnet backend also no
//! longer lets the enclosing function's return type override a type argument
//! the constructor's own argument pins when that type cannot hold the
//! argument.  The `try` cases are `propagate_ctor_operand_try_self_test.l`
//! (the native target has no `try`, D-N-003).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/propagate_ctor_operand_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/propagate_ctor_operand_self_test.l
//!   lyric test --target native lyric-compiler/lyric/propagate_ctor_operand_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.PropagateCtorOperandSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Label {
  text: String
}

func two(a: in String, b: in String): Int {
  a.length + b.length
}

func okAsArgument(): Result[Int, String] {
  val s = "a"
  val n = two(s, Ok(value = "bb")?)
  Ok(value = n)
}

func okAsInit(): Result[Int, String] {
  val m = Ok(value = "bb")?
  Ok(value = m.length)
}

func okOtherErrorType(): Result[Int, Int] {
  val m = Ok(value = "xyz")?
  Ok(value = m.length)
}

func okMember(): Result[Int, String] {
  Ok(value = 1 + Ok(value = "four")?.length)
}

func errAtStringPosition(fail: in Bool): Result[Int, String] {
  if fail {
    val s: String = Err(error = "boom")?
    return Ok(value = s.length)
  }
  Ok(value = 1)
}

func errStatement(fail: in Bool): Result[Int, String] {
  if fail {
    Err(error = "stopped")?
  }
  Ok(value = 1)
}

func errDiscarded(fail: in Bool): Result[Int, String] {
  if fail {
    val _ = Err(error = "discarded")?
  }
  Ok(value = 2)
}

func noneStatement(fail: in Bool): Option[Int] {
  if fail {
    None?
  }
  Some(value = 3)
}

func someAsInit(): Option[Int] {
  val s = Some(value = "abc")?
  Some(value = s.length)
}

func someAsArgument(): Option[Int] {
  Some(value = two("a", Some(value = "bcd")?))
}

func noneAtStringPosition(fail: in Bool): Option[Int] {
  if fail {
    val s: String = None?
    return Some(value = s.length)
  }
  Some(value = 2)
}

func someRecord(): Option[Label] {
  val s = Some(value = "label")?
  Some(value = Label(text = s))
}

func okLocal(): Result[Int, String] {
  val r = Ok(value = "four")
  val s = r?
  Ok(value = s.length)
}

func okInIf(c: in Bool): Result[Int, String] {
  val n = two("a", if c { Ok(value = "bb")? } else { "c" })
  Ok(value = n)
}

func ifOperand(c: in Bool): Result[Int, String] {
  val s = (if c { Ok(value = "yes") } else { Err(error = "no") })?
  Ok(value = s.length)
}

func errInIf(c: in Bool): Result[Int, String] {
  val s = if c { Err(error = "then")? } else { "else" }
  Ok(value = s.length)
}

func noneInMatch(n: in Int): Option[Int] {
  val s = match n { case 0 -> None?; case _ -> "some" }
  Some(value = s.length)
}

func okInMatch(n: in Int): Result[Int, String] {
  val s = match n { case 0 -> Ok(value = "zero")?; case 1 -> Err(error = "one")?; case _ -> "many" }
  Ok(value = s.length)
}

func okGeneric[T](x: in T, s: in String): Result[T, String] {
  val m = Ok(value = s)?
  if m.length > 3 {
    return Err(error = m)
  }
  Ok(value = x)
}

func okTypeParamOperand[T](x: in T): Result[T, String] {
  val y = Ok(value = x)?
  Ok(value = y)
}

async func okAsync(): Result[Int, String] {
  val m = Ok(value = "async")?
  Ok(value = m.length)
}

// Without `?`: a bare construction that is not the function's result keeps
// the instantiation its argument gives it.
func someLocalMatched(): Option[Int] {
  val r = Some(value = "four")
  match r {
    case Some(s) -> Some(value = s.length)
    case None -> None
  }
}

func boolLocalMatched(): Option[Int] {
  val r = Some(value = true)
  match r {
    case Some(b) -> if b { Some(value = 1) } else { Some(value = 0) }
    case None -> None
  }
}

func strRes(n: in Int): Result[String, String] {
  Ok(value = "s" + toString(n))
}

// An `if`/`match` operand whose first branch fixes no success type takes it
// from a later branch.
func errFirstIf(c: in Bool): Result[String, String] {
  val s = (if c { Err(error = "z") } else { Ok(value = "abc") })?
  Ok(value = "x" + s)
}

func errFirstIfArg(c: in Bool): Result[Int, String] {
  val s = (if c { Err(error = "z") } else { Ok(value = "abcd") })?
  Ok(value = two("a", s))
}

func noneFirstIf(c: in Bool): Option[Int] {
  val s = (if c { None } else { Some(value = "abc") })?
  if s == "abc" {
    Some(value = 1)
  } else {
    Some(value = 0)
  }
}

func errFirstMatchCall(n: in Int): Result[Int, String] {
  val s = (match n { case 0 -> Err(error = "zero"); case _ -> strRes(n) })?
  Ok(value = s.length)
}

func errFirstUnparenthesized(c: in Bool): Result[Int, String] {
  val s = if c { Err(error = "zero") } else { Ok(value = "abc") }?
  Ok(value = s.length)
}

func errFirstLocal(c: in Bool): Result[Int, String] {
  val r = if c { Err(error = "zero") } else { Ok(value = "abc") }
  val s = r?
  Ok(value = s.length)
}

// An `Err` operand that fixes no success type takes the type of the position
// that consumes it.
func errCallArg(fail: in Bool): Result[Int, String] {
  if fail {
    return Ok(value = two("a", Err(error = "arg")?))
  }
  Ok(value = 1)
}

func errRecordField(fail: in Bool): Result[Int, String] {
  if fail {
    val l = Label(text = Err(error = "field")?)
    return Ok(value = l.text.length)
  }
  Ok(value = 1)
}

func errListAdd(fail: in Bool): Result[Int, String] {
  val xs: List[String] = newList()
  if fail {
    xs.add(Err(error = "add")?)
  }
  Ok(value = xs.count)
}

func errBinop(fail: in Bool): Result[Int, String] {
  if fail {
    if Err(error = "eq")? == "s" {
      return Ok(value = 9)
    }
  }
  val t = "a" + (if fail { Err(error = "concat")? } else { "b" })
  Ok(value = t.length)
}

func errCondition(fail: in Bool): Result[Int, String] {
  var n = 0
  if fail {
    if Err(error = "cond")? {
      n = 1
    }
  }
  while n < 2 and not (if fail { Err(error = "while")? } else { false }) {
    n = n + 1
  }
  Ok(value = n)
}

func errInterpolated(fail: in Bool): Result[Int, String] {
  if fail {
    val s = "v=${Err(error = "interp")?}"
    return Ok(value = s.length)
  }
  Ok(value = 1)
}

func errReturned(fail: in Bool): Result[String, String] {
  if fail {
    return Ok(value = Err(error = "returned")?)
  }
  Ok(value = "x")
}

func logged(log: in List[String], s: in String): String {
  log.add(s)
  s
}

func three(a: in String, b: in String, c: in String): Int {
  a.length * 100 + b.length * 10 + c.length
}

func errShortCircuitsRest(log: in List[String]): Result[Int, String] {
  val n = three(logged(log, "a"), Err(error = logged(log, "E"))?, logged(log, "never"))
  Ok(value = n)
}

func pass[T](x: in T): T {
  x
}

func lenOf(s: in String): Int {
  s.length
}

// A generic call that is itself an argument takes its result type from the
// outer parameter.
func errNestedGeneric(fail: in Bool): Result[Int, String] {
  if fail {
    return Ok(value = lenOf(pass(Err(error = "nested")?)))
  }
  Ok(value = 0)
}

func errNestedGenericTwice(fail: in Bool): Result[Int, String] {
  if fail {
    return Ok(value = lenOf(pass(pass(Err(error = "twice")?))))
  }
  Ok(value = 0)
}

func errNestedGenericMethod(fail: in Bool): Result[Int, String] {
  val xs: List[String] = newList()
  if fail {
    xs.add(pass(Err(error = "method")?))
  }
  Ok(value = xs.count)
}

// An error type that widens to the function's is converted when re-wrapped.
func errWidens(fail: in Bool): Result[Int, Long] {
  if fail {
    val s: String = Err(error = 5)?
    return Ok(value = s.length)
  }
  Ok(value = 0)
}

func intErr(n: in Int): Result[Int, Int] {
  if n < 0 {
    Err(error = n)
  } else {
    Ok(value = n)
  }
}

func callErrWidens(n: in Int): Result[Int, Long] {
  val v = intErr(n)?
  Ok(value = v + 1)
}

func nestedErrWidens(r: in Result[Result[Int, Int], Int]): Result[Int, Long] {
  Ok(value = (r?)?)
}

func resLong(r: in Result[Int, Long]): String {
  match r {
    case Ok(v) -> "ok " + toString(v)
    case Err(e) -> "err " + toString(e + 1i64)
  }
}

// An operand that can never be `Ok`/`Some`, where nothing consuming the `?`
// gives it a success type: the `?` always returns.
func errTupleElement(fail: in Bool): Result[Int, String] {
  if fail {
    val (unused, n) = (Err(error = "tuple")?, 1)
    return Ok(value = n)
  }
  Ok(value = 1)
}

func errGenericArgument(fail: in Bool): Result[Int, String] {
  if fail {
    val s: String = pass(Err(error = "generic")?)
    return Ok(value = s.length)
  }
  Ok(value = 1)
}

func noneUnannotated(fail: in Bool): Option[Int] {
  if fail {
    val unused = None?
  }
  Some(value = 1)
}

func resInt(r: in Result[Int, String]): String {
  match r {
    case Ok(v) -> "ok " + toString(v)
    case Err(e) -> "err " + e
  }
}

func resIntInt(r: in Result[Int, Int]): String {
  match r {
    case Ok(v) -> "ok " + toString(v)
    case Err(e) -> "err " + toString(e)
  }
}

func resStr(r: in Result[String, String]): String {
  match r {
    case Ok(v) -> "ok " + v
    case Err(e) -> "err " + e
  }
}

func optInt(o: in Option[Int]): String {
  match o {
    case Some(v) -> "some " + toString(v)
    case None -> "none"
  }
}

test "an Ok operand of another success type, as a call argument" {
  assertEqual(resInt(okAsArgument()), "ok 3", "two(\"a\", \"bb\")")
}

test "an Ok operand of another success type, as an initializer" {
  assertEqual(resInt(okAsInit()), "ok 2", "\"bb\".length")
  assertEqual(resIntInt(okOtherErrorType()), "ok 3", "the function's error type is Int")
  assertEqual(resInt(okMember()), "ok 5", "member access on the unwrapped value")
}

test "an Err operand where the position expects another success type" {
  assertEqual(resInt(errAtStringPosition(true)), "err boom", "propagated")
  assertEqual(resInt(errAtStringPosition(false)), "ok 1", "not reached")
}

test "an Err or None operand nothing gives a success type" {
  assertEqual(resInt(errStatement(true)), "err stopped", "a statement")
  assertEqual(resInt(errStatement(false)), "ok 1", "a statement, not reached")
  assertEqual(resInt(errDiscarded(true)), "err discarded", "bound to `_`")
  assertEqual(resInt(errDiscarded(false)), "ok 2", "bound to `_`, not reached")
  assertEqual(optInt(noneStatement(true)), "none", "a None statement")
  assertEqual(optInt(noneStatement(false)), "some 3", "a None statement, not reached")
}

test "a Some operand of another element type" {
  assertEqual(optInt(someAsInit()), "some 3", "\"abc\".length")
  assertEqual(optInt(someAsArgument()), "some 4", "two(\"a\", \"bcd\")")
  match someRecord() {
    case Some(l) -> assertEqual(l.text, "label", "a record built from the unwrapped value")
    case None -> assertTrue(false, "someRecord returned None")
  }
}

test "a None operand where the position expects another element type" {
  assertEqual(optInt(noneAtStringPosition(true)), "none", "propagated")
  assertEqual(optInt(noneAtStringPosition(false)), "some 2", "not reached")
}

test "a local holding an Ok of another success type" {
  assertEqual(resInt(okLocal()), "ok 4", "\"four\".length")
}

test "an Ok operand inside an if branch, and an if as the operand" {
  assertEqual(resInt(okInIf(true)), "ok 3", "then branch")
  assertEqual(resInt(okInIf(false)), "ok 2", "else branch")
  assertEqual(resInt(ifOperand(true)), "ok 3", "Ok branch")
  assertEqual(resInt(ifOperand(false)), "err no", "Err branch propagated")
  assertEqual(resInt(errInIf(true)), "err then", "an Err operand in the then branch")
  assertEqual(resInt(errInIf(false)), "ok 4", "the else branch")
}

test "Ok and Err operands in match arms" {
  assertEqual(resInt(okInMatch(0)), "ok 4", "Ok arm")
  assertEqual(resInt(okInMatch(1)), "err one", "Err arm propagated")
  assertEqual(resInt(okInMatch(2)), "ok 4", "plain arm")
  assertEqual(optInt(noneInMatch(0)), "none", "a None operand in an arm")
  assertEqual(optInt(noneInMatch(1)), "some 4", "the plain arm")
}

test "an Ok operand in a generic function" {
  match okGeneric(7, "ab") {
    case Ok(v) -> assertEqualInt(v, 7, "the generic success value")
    case Err(e) -> assertEqual(e, "", "unexpected Err")
  }
  match okGeneric("v", "abcd") {
    case Ok(v) -> assertEqual(v, "", "unexpected Ok")
    case Err(e) -> assertEqual(e, "abcd", "Err built from the unwrapped value")
  }
}

test "an Ok operand of the type parameter in a generic function" {
  match okTypeParamOperand(8) {
    case Ok(v) -> assertEqualInt(v, 8, "Int instantiation")
    case Err(e) -> assertEqual(e, "", "unexpected Err")
  }
  match okTypeParamOperand("w") {
    case Ok(v) -> assertEqual(v, "w", "String instantiation")
    case Err(e) -> assertEqual(e, "", "unexpected Err")
  }
}

test "an Ok operand in an async function" {
  assertEqual(resInt(await okAsync()), "ok 5", "\"async\".length")
}

test "a bare construction that is not the function's result" {
  assertEqual(optInt(someLocalMatched()), "some 4", "Some(\"four\") in an Option[Int] function")
  assertEqual(optInt(boolLocalMatched()), "some 1", "Some(true) in an Option[Int] function")
}

test "an if or match operand whose first branch fixes no success type" {
  assertEqual(resStr(errFirstIf(false)), "ok xabc", "Err-first if, Ok branch")
  assertEqual(resStr(errFirstIf(true)), "err z", "Err-first if, Err branch")
  assertEqual(resInt(errFirstIfArg(false)), "ok 5", "the unwrapped value as a call argument")
  assertEqual(optInt(noneFirstIf(false)), "some 1", "None-first if, Some branch")
  assertEqual(optInt(noneFirstIf(true)), "none", "None-first if, None branch")
  assertEqual(resInt(errFirstMatchCall(12)), "ok 3", "Err-first match, call arm")
  assertEqual(resInt(errFirstMatchCall(0)), "err zero", "Err-first match, Err arm")
  assertEqual(resInt(errFirstUnparenthesized(false)), "ok 3", "unparenthesized if, Ok branch")
  assertEqual(resInt(errFirstUnparenthesized(true)), "err zero", "unparenthesized if, Err branch")
  assertEqual(resInt(errFirstLocal(false)), "ok 3", "a local of the if, Ok branch")
  assertEqual(resInt(errFirstLocal(true)), "err zero", "a local of the if, Err branch")
}

test "an Err operand takes the type of the position consuming it" {
  assertEqual(resInt(errCallArg(true)), "err arg", "a call argument")
  assertEqual(resInt(errCallArg(false)), "ok 1", "a call argument, not reached")
  assertEqual(resInt(errRecordField(true)), "err field", "a record field")
  assertEqual(resInt(errRecordField(false)), "ok 1", "a record field, not reached")
  assertEqual(resInt(errListAdd(true)), "err add", "a List.add argument")
  assertEqual(resInt(errListAdd(false)), "ok 0", "a List.add argument, not reached")
  assertEqual(resInt(errBinop(true)), "err eq", "a binary operand")
  assertEqual(resInt(errBinop(false)), "ok 2", "a binary operand, not reached")
  assertEqual(resInt(errCondition(true)), "err cond", "an if condition")
  assertEqual(resInt(errCondition(false)), "ok 2", "a while condition, not reached")
  assertEqual(resInt(errInterpolated(true)), "err interp", "an interpolated segment")
  assertEqual(resInt(errInterpolated(false)), "ok 1", "an interpolated segment, not reached")
  assertEqual(resStr(errReturned(true)), "err returned", "a returned constructor's field")
  assertEqual(resStr(errReturned(false)), "ok x", "a returned constructor's field, not reached")
}

test "an Err argument returns before the later arguments run" {
  val log: List[String] = newList()
  assertEqual(resInt(errShortCircuitsRest(log)), "err E", "propagated")
  assertEqualInt(log.count, 2, "two arguments ran")
  assertEqual(log[0], "a", "the first argument ran")
  assertEqual(log[1], "E", "the Err's own argument ran")
}

test "an Err or None operand whose value nothing types" {
  assertEqual(resInt(errTupleElement(true)), "err tuple", "a tuple element")
  assertEqual(resInt(errTupleElement(false)), "ok 1", "a tuple element, not reached")
  assertEqual(resInt(errGenericArgument(true)), "err generic", "a generic argument")
  assertEqual(resInt(errGenericArgument(false)), "ok 1", "a generic argument, not reached")
  assertEqual(optInt(noneUnannotated(true)), "none", "an unannotated binding")
  assertEqual(optInt(noneUnannotated(false)), "some 1", "an unannotated binding, not reached")
}

test "an Err operand of a generic call that is itself an argument" {
  assertEqual(resInt(errNestedGeneric(true)), "err nested", "a function argument")
  assertEqual(resInt(errNestedGeneric(false)), "ok 0", "a function argument, not reached")
  assertEqual(resInt(errNestedGenericTwice(true)), "err twice", "two generic calls deep")
  assertEqual(resInt(errNestedGenericTwice(false)), "ok 0", "two generic calls deep, not reached")
  assertEqual(resInt(errNestedGenericMethod(true)), "err method", "a method argument")
  assertEqual(resInt(errNestedGenericMethod(false)), "ok 0", "a method argument, not reached")
}

test "an error type that widens to the function's" {
  assertEqual(resLong(errWidens(true)), "err 6", "a constructor operand")
  assertEqual(resLong(errWidens(false)), "ok 0", "not reached")
  assertEqual(resLong(callErrWidens(-3)), "err -2", "a call operand")
  assertEqual(resLong(callErrWidens(4)), "ok 5", "a call operand, Ok")
  val innerErr: Result[Result[Int, Int], Int] = Ok(value = Err(error = 5))
  assertEqual(resLong(nestedErrWidens(innerErr)), "err 6", "the inner `?` of `(r?)?`")
  val outerErr: Result[Result[Int, Int], Int] = Err(error = 7)
  assertEqual(resLong(nestedErrWidens(outerErr)), "err 8", "the outer `?` of `(r?)?`")
  val okBoth: Result[Result[Int, Int], Int] = Ok(value = Ok(value = 9))
  assertEqual(resLong(nestedErrWidens(okBoth)), "ok 9", "both Ok")
}
