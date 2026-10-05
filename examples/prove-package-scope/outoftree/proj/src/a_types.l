//! `proj/lyric.toml` lists `../shared/b_logic.l`, outside its tree: this
//! `Option` is in scope there in that build.  A single-file proof of the
//! shared file cannot find this manifest; prove it with --manifest (#8108).
package P

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
