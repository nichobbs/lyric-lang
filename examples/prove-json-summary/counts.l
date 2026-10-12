//! One obligation of each outcome, for the `lyric prove --json` summary
//! (#8307): `copy`'s postcondition is discharged, `bump`'s is refuted with a
//! counterexample, and `noCubeSum`'s is undecided — `x^3 + y^3 + z^3 == 42`
//! has a solution in `Long`, which the solver cannot find within its time
//! limit.
@proof_required
package ProveJsonSummary

func copy(x: in Int): Int
  ensures: result == x
{
  x
}

func bump(x: in Int): Int
  ensures: result > x
{
  x
}

func noCubeSum(x: in Long, y: in Long, z: in Long): Bool
  ensures: x * x * x + y * y * y + z * z * z != 42
{
  true
}
