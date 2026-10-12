//! Proved: its package type-checks.
@proof_required
package P

func twice(n: in Int): Int
  requires: n >= 0 and n <= 1000
  ensures: result == n * 2
{
  n * 2
}
