//! loops.l - loop `invariant:` clauses lowered from TIR (docs/70 phase 3c, D510): checked at the head of every
//! iteration and when the loop ends normally, but not after a `break`.  The last call violates an invariant at the
//! exit of a `while` and panics.  `native-via-tir-e2e.sh` runs it both ways.
package LoopsViaTir

import Std.Core
import Std.Console as Console

func sumTo(n: in Int): Int {
  var s = 0
  var i = 0
  while i < n
    invariant: s >= 0
  {
    s = s + i
    i = i + 1
  }
  s
}

func firstBig(n: in Int): Int {
  var s = 0
  for i in 0 ..< n
    invariant: s >= 0
  {
    if i > 3 {
      break
    }
    s = s + i
  }
  s
}

func breakExempt(): Int {
  var s = 0
  for i in 0 ..< 10
    invariant: s < 4
  {
    if i == 3 {
      s = 100
      break
    }
    s = s + 1
  }
  s
}

func exitOnly(n: in Int): Int {
  var i = 0
  while i < n
    invariant: i != 3
  {
    i = i + 1
  }
  i
}

func main(): Unit {
  println(toString(sumTo(4)))
  println(toString(firstBig(10)))
  println(toString(breakExempt()))
  println(toString(exitOnly(2)))
  println(toString(exitOnly(3)))
}
