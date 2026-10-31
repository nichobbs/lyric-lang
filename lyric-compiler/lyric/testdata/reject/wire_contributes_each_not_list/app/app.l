package App

import Std.Collections

interface Exporter {
  func name(): String
}

wire W {
  contributes[Exporter] each extra = 42
  expose Exporter
}

func main(): Int {
  0
}
