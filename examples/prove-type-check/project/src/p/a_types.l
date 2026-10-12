//! A sibling file the type checker rejects (T0031: an `Int` plus a
//! `String`).  The package does not build, so nothing in it is proved,
//! not even `b_logic.l`'s sound obligation (#8227).
package P

record Meter {
  n: Int
}

func bad(m: in Meter): Int {
  m.n + "1"
}
