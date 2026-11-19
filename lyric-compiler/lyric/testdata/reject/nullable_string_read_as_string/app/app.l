package App

func firstOrNone(xs: in slice[String]): String? {
  if xs.length > 0 { Some(value = xs[0]) } else { None }
}

// A `String?` is not a `String`: only a host result the kernel declares is read as one (D435).
func shout(xs: in slice[String]): String {
  val name: String? = firstOrNone(xs)
  val plain: String = name
  plain
}

func main(): Int {
  0
}
