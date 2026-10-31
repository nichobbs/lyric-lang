package App

protected type Counter {
  var total: Int = 0
  entry add(n: in Int) {
    total = total + n
  }
  func get(): Int {
    total
  }
}

func main(): Int {
  val c = Counter()
  c.total = 5
  c.get() + c.total
}
