package Zed

pub func frob(o: in Option[Int]): Int {
  match o {
    case Some(v) -> v
    case None -> 0
  }
}
