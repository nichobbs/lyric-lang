package App

enum Color {
  case Red
  case Green
}

// A bare enum case is a `Color`, not a `String` (#8652).
func main(): Unit {
  val z: String = Green
  println(z)
}
