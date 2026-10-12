//! Two manifests build this package: a single-file proof of this file
//! reads `a.l` once, so `I` is declared once, and `R.f`, which returns `k`
//! where `I.f` promises more than 100, is refuted (#8231).
@proof_required
package P

record R {
  n: Int
}

impl I for R {
  func f(self: in R, k: in Int): Int {
    k
  }
}
