package App

union Shape {
  case Rect(w: Int, h: Int)
  case Dot
}

func area(s: in Shape): Int {
  match s {
    case Rect(w, h, d) -> w * h
    case Dot -> 0
  }
}

func main(): Int {
  area(Rect(w = 2, h = 3))
}
