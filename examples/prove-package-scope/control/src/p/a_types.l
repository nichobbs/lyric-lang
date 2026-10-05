//! A sibling file declaring an unrelated type: `b_logic.l`'s `Option` is
//! still the standard library's (#8108).
package P

record Helper {
  n: Int
}

func main(): Unit {
  println(toString(Helper(n = 1).n))
}
