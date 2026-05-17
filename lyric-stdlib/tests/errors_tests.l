// stdlib/tests/errors_tests.l — Tests for Std.Errors.
//
// Verifies that the union constructors exist and that the `message`
// helper renders a non-empty, human-readable string for every variant.
package Std.Errors.Tests

import Std.Errors
import Std.Testing

func testParseError(): Unit {
  val fmt = InvalidFormat(input = "abc", expected = "Int")
  val msg = ParseError.message(fmt)
  assertTrue(msg.length > 0, "InvalidFormat message non-empty")
  assertTrue(msg.contains("abc"), "InvalidFormat message contains input")

  val oor = OutOfRange(value = "999", bounds = "0..100")
  val msg2 = ParseError.message(oor)
  assertTrue(msg2.length > 0, "OutOfRange message non-empty")
  assertTrue(msg2.contains("999"), "OutOfRange message contains value")
}

func testIOError(): Unit {
  val notFound = FileNotFound(path = "/tmp/x.txt")
  val msg = IOError.message(notFound)
  assertTrue(msg.contains("/tmp/x.txt"), "FileNotFound message contains path")

  val perm = PermissionDenied(path = "/root/secret")
  assertTrue(IOError.message(perm).length > 0, "PermissionDenied message non-empty")

  val ioErr = IoError(path = "/dev/null", message = "disk full")
  assertTrue(IOError.message(ioErr).contains("disk full"), "IoError message contains detail")

  val eoi = EndOfInput(source = "stdin")
  assertTrue(IOError.message(eoi).contains("stdin"), "EndOfInput message contains source")

  val knf = KeyNotFound(key = "HOME")
  assertTrue(IOError.message(knf).contains("HOME"), "KeyNotFound message contains key")
}

func testHttpError(): Unit {
  val cf = ConnectionFailed(url = "http://x.example", message = "refused")
  assertTrue(HttpError.message(cf).contains("refused"), "ConnectionFailed message contains detail")

  val bs = BadStatus(url = "http://x.example", statusCode = 404)
  assertTrue(HttpError.message(bs).contains("404"), "BadStatus message contains code")

  val iu = InvalidUrl(url = "not-a-url")
  assertTrue(HttpError.message(iu).contains("not-a-url"), "InvalidUrl message contains url")
}

func main(): Unit {
  testParseError()
  testIOError()
  testHttpError()
  println("errors: ok")
}
