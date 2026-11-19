package App

// A `String?` is not a `String`: only a host result the kernel declares is read as one (D435).
func shout(name: in String?): String {
  val plain: String = name
  plain
}

func main(): Int {
  0
}
