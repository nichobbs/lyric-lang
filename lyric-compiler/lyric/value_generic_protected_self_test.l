//! Value-generic protected types (#8149): a protected type's `N: Nat`
//! parameter sizes its array fields.  Each length a program uses is its own
//! type with its own layout, lock and members (the declaration is specialised
//! whole, with `N` replaced by the length, on every target); a member reads
//! `N` and the field arrays by bare name.
//! Run on dotnet, the JVM and native.
@test_module
package Lyric.ValueGenericProtectedSelfTest

import Std.Testing

protected type Ring[N: Nat] {
  var buf: array[N, Int]
  var next: Int = 0
  var filled: Int = 0
  entry push(v: in Int): Unit {
    buf[next] = v
    next = (next + 1) % N
    if filled < N {
      filled = filled + 1
    }
  }
  func capacity(): Int = N
  func length(): Int = buf.length
  func total(): Int {
    var t = 0
    for x in buf {
      t = t + x
    }
    t
  }
  func count(): Int = filled
}

protected type Slots[T, N: Nat] {
  var items: array[N, T]
  var used: Int = 0
  entry put(v: in T): Unit {
    items[used] = v
    used = used + 1
  }
  func first(): T = items[0]
  func size(): Int = N
}

test "a construction binds the length from an array field" {
  val a: array[3, Int] = [0, 0, 0]
  val r = Ring(buf = a)
  assertEqualInt(r.capacity(), 3, "N in a member body")
  assertEqualInt(r.length(), 3, "the field array's length")
  r.push(4)
  r.push(5)
  assertEqualInt(r.total(), 9, "the entry wrote the field array")
  assertEqualInt(r.count(), 2, "a defaulted field")
}

test "two lengths are two types with their own members" {
  val a: array[2, Int] = [0, 0]
  val b: array[4, Int] = [0, 0, 0, 0]
  val x = Ring(buf = a)
  val y = Ring(buf = b)
  x.push(1)
  x.push(2)
  x.push(3)
  y.push(7)
  assertEqualInt(x.capacity() + y.capacity(), 6, "capacities")
  assertEqualInt(x.total(), 5, "the shorter ring wrapped")
  assertEqualInt(y.total(), 7, "the longer ring")
}

test "a length from the expected type zero fills the array field" {
  val z: Ring[5] = Ring()
  assertEqualInt(z.capacity(), 5, "length from the type")
  assertEqualInt(z.total(), 0, "zero filled")
}

test "a type and a value parameter together" {
  val names: array[2, String] = ["", ""]
  val s = Slots(items = names)
  s.put("a")
  s.put("b")
  assertEqual(s.first(), "a", "a reference element")
  assertEqualInt(s.size(), 2, "N with a type parameter")
  val nums: array[3, Long] = [0i64, 0i64, 0i64]
  val n = Slots(items = nums)
  n.put(9i64)
  assertTrue(n.first() == 9i64, "a second instantiation")
}

// A barrier and an invariant that name `N`: each length has its own copy of
// both, with the length substituted.
protected type Mailbox[N: Nat] {
  var slots: array[N, Int]
  var used: Int = 0
  invariant: used >= 0 and used <= N
  entry put(v: in Int): Unit
    when: used < N
  {
    slots[used] = v
    used = used + 1
  }
  entry take(): Int
    when: used > 0
  {
    used = used - 1
    slots[used]
  }
  func pending(): Int = used
}

test "a barrier and an invariant name the length" {
  val a: array[2, Int] = [0, 0]
  val b: array[3, Int] = [0, 0, 0]
  val small = Mailbox(slots = a)
  val big = Mailbox(slots = b)
  small.put(1)
  small.put(2)
  big.put(7)
  big.put(8)
  big.put(9)
  assertEqualInt(small.pending() + big.pending(), 5, "both filled to their own length")
  assertEqualInt(small.take(), 2, "last in, first out")
  assertEqualInt(big.take(), 9, "the longer mailbox")
  assertEqualInt(small.pending() + big.pending(), 3, "after one take each")
}

func newRing(): Ring[3] {
  val a: array[3, Int] = [0, 0, 0]
  Ring(buf = a)
}

func fillRing(r: in Ring[3], v: in Int): Unit {
  r.push(v)
}

test "a function takes and returns an instance of one length" {
  val r = newRing()
  fillRing(r, 6)
  fillRing(r, 7)
  assertEqualInt(r.total(), 13, "the function's instance is the caller's")
  assertEqualInt(r.capacity(), 3, "its length")
}
