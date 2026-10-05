//! The build merges every file of a manifest entry whatever its `package`
//! line: this `Option` is in scope in `b_logic.l` (#8108).
package Q

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
