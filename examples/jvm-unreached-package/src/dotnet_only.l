//! A package for the dotnet target only; its type error is reported on
//! dotnet and never on the JVM.
@cfg(target = "dotnet")
package DotnetOnly

pub func dotnetBroken(): Int {
  "not an int"
}
