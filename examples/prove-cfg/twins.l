//! Two declarations of one name, each gated to a different target: `lyric
//! prove` proves the one the build compiles for `--target`, as `lyric build`
//! erases the other, instead of seeing both (#8325).
@proof_required
package Twins

@cfg(target = "jvm")
pub func width(): Int
  ensures: result == 64
{
  64
}

@cfg(not(target = "jvm"))
pub func width(): Int
  ensures: result == 32
{
  32
}

pub func positiveWidth(): Int
  ensures: result > 0
{
  width()
}
