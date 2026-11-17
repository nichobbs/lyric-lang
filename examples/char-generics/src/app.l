package CharGenApp

import Std.Core
import Std.Collections
import Std.Console
import CharGenLib

func main(): Int {
  val c: Char = 'q'
  println(concatLeft(c))
  println(concatLeft(65))
  println(showToString(c))
  println(showToString(67))
  println(showInterpolated(c))
  println(showInterpolated(68))
  println(showViaHelper(c))
  println(showViaHelper(69))
  println(showBoxed(Box(value = c)))
  println(showBoxed(Box(value = 70)))
  val cs: List[Char] = ['a', 'b']
  val ns: List[Int] = [97, 98]
  println(showAll(cs))
  println(showAll(ns))
  println(twice(c))
  println(twice(71))
  println(showToString(pick(c)))
  println(showToString(pick(72)))
  println(showMaybe(Just(value = c)))
  println(showMaybe(Just(value = 74)))
  println(showOption(Some(value = c)))
  println(showOption(Some(value = 75)))
  println(showPair(c, 76))
  println(showPair(77, c))
  println(showUnwrapped(Box(value = c)))
  println(showUnwrapped(Box(value = 78)))
  0
}
