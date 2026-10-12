//! Two declarations of `limit`, one per setting of the feature `wide`:
//! `lyric prove` sees the one the build compiles.  `atLeastHundred` holds
//! only with `--features wide`; without it the proof refutes it, using the
//! narrow twin's contract (#8325).
@proof_required
package P

@cfg(feature = "wide")
pub func limit(): Int
  ensures: result == 1000
{
  1000
}

@cfg(not(feature = "wide"))
pub func limit(): Int
  ensures: result == 10
{
  10
}

pub func atLeastHundred(): Int
  ensures: result >= 100
{
  limit()
}
