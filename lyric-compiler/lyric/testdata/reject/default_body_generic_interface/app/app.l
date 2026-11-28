package App

interface Holder[T] {
  func get(self: in Self): T
  func twice(self: in Self): T = 5
}

// `T` is rigid inside the default body, so an Int is not a `T`.
func main(): Int {
  0
}
