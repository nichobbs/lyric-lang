//! A sibling file declaring its own `Option`, which `b_logic.l` uses: the
//! verifier must not model it as the standard library's (#8108).
package P

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
