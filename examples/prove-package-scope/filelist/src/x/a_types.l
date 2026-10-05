//! An explicit file list may span directories: this `Option` is in scope
//! in `../y/b_logic.l` (#8108).
package P

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
