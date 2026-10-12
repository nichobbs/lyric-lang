//! The union `b_logic.l` matches on, declared in another file of the package.
package P

pub union Opt {
  case Has(v: Int)
  case Nothing
  case Other
}
