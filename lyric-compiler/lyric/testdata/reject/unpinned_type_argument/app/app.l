package App

// Nothing fixes `T` of `isNone`: the argument `None` carries no type and the
// result is a Bool.  The call used to be specialised at `Object`; it is T0224
// since D335 (docs/70 §5.2).  Writing `isNone[Int](None)` is accepted.
func main(): Unit {
  val empty = isNone(None)
  println(toString(empty))
}
