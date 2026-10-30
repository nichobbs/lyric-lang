package Lib

record Secret {
  n: Int
}

pub func make(): Secret {
  Secret(n = 1)
}
