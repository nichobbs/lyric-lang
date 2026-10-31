package Lib

pub protected type Counter {
  var total: Int = 0
  entry add(n: in Int) {
    total = total + n
  }
  func get(): Int {
    total
  }
}
