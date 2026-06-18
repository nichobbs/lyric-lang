// First real-world program through the bootstrap CLI.
//
// Parses a tiny inline CSV string (comma-separated, no quoting yet
// — bootstrap-grade) and prints each row's fields one per line.

package CsvDemo

// Print each comma-separated field of `line` on its own line.
func printFields(line: in String): Unit {
  val n = line.length
  var fieldStart = 0
  var i = 0
  while i < n {
    if line[i] == ',' {
      println(line.substring(fieldStart, i - fieldStart))
      fieldStart = i + 1
    }
    i += 1
  }
  println(line.substring(fieldStart, n - fieldStart))
}

func main(): Unit {
  val source = "alice,30,gardener\nbob,42,baker\ncarol,7,inventor"
  val n = source.length
  var lineStart = 0
  var i = 0
  var rowIdx = 0
  while i < n {
    if source[i] == '\n' {
      println("--- row " + rowIdx)
      printFields(source.substring(lineStart, i - lineStart))
      lineStart = i + 1
      rowIdx += 1
    }
    i += 1
  }
  println("--- row " + rowIdx)
  printFields(source.substring(lineStart, n - lineStart))
}
