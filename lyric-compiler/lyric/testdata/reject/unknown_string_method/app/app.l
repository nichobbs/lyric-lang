package App

// `toLowerInvariant` is no `String` method on either target: not one the
// lowering implements, and not a method of java.lang.String (#7204, D299).
func main(): Unit {
  val s = "ABC"
  println(s.toLowerInvariant())
}
