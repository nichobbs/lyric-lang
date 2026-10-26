//! A program with a `config { }` block.  The dotnet and JVM builds compile
//! it; the native build rejects the block (N0025), and so does `lyric prove
//! --target native`, whose check is the native bridge's own front end
//! (#8311).
@proof_required
package ConfigBlockUse

config Settings {
  port: Int = 8080
}

func pick(x: in Int): Int
  requires: x != 0
  ensures: result == x
{
  x
}
