//! A program whose `main` returns `Long`.  The dotnet build compiles it; the
//! JVM build rejects it (J001: its entry wrapper discards a one-slot value),
//! and so does `lyric prove --target jvm`, whose check is the JVM bridge's
//! own front end (#8311).
@proof_required
package MainLong

func pick(x: in Int): Int
  requires: x != 0
  ensures: result == x
{
  x
}

func main(): Long {
  0
}
