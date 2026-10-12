//! A `@proof_required` function only the JVM build compiles: a dotnet proof
//! says it is not proved, instead of reporting success silently (#8325).
@proof_required
package JvmOnly

@cfg(target = "jvm")
pub func onJvm(): Int
  ensures: result == 1
{
  1
}

pub func always(): Int
  ensures: result == 2
{
  2
}
