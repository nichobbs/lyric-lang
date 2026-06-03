// Classic FizzBuzz, end-to-end through the bootstrap CLI.
//
// Run: lyric run examples/fizzbuzz.l

package FizzBuzz

func main(): Unit {
  var i = 1
  while i <= 30 {
    if i % 15 == 0 {
      println("FizzBuzz")
    } else if i % 3 == 0 {
      println("Fizz")
    } else if i % 5 == 0 {
      println("Buzz")
    } else {
      println(i)
    }
    i += 1
  }
}
