// First N primes via trial division, end-to-end through the
// bootstrap CLI.
//
// Run: lyric run examples/primes.l

package Primes

@pure
func isPrime(n: in Int): Bool {
  if n < 2 {
    false
  } else {
    var i = 2
    var prime = true
    while i * i <= n and prime {
      if n % i == 0 {
        prime = false
      }
      i += 1
    }
    prime
  }
}

func main(): Unit {
  val target = 15
  var found = 0
  var n = 2
  while found < target {
    if isPrime(n) {
      println(n)
      found += 1
    }
    n += 1
  }
}
