// std/_kernel/uuid_host.l — host boundary for System.Guid (UUID).
//
// `Uuid` is a thin alias over `System.Guid`.  The four operations below
// cover the full lifecycle: generation, the nil/empty sentinel, string
// formatting, and round-trip parsing.
//
// `hostGuidToString` routes to the instance `System.Guid.ToString()` call
// which produces the canonical lowercase hyphenated form
// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
//
// `hostTryParseGuid` uses the static `System.Guid.TryParse(string, out Guid)`
// overload; it accepts all standard Guid formats ("D", "N", "B", "P", "X").
//
// Internal: only Std.Uuid should import this.

@axiom("System.Guid conforms to its documented .NET contract")
package Std.UuidHost

extern type Uuid = "System.Guid"

// Generate a new random (version 4) UUID.
@externTarget("System.Guid.NewGuid")
pub func hostNewGuid(): Uuid = ()

// The nil UUID: 00000000-0000-0000-0000-000000000000.
@externTarget("System.Guid.Empty")
pub func hostEmptyGuid(): Uuid = ()

// Format a UUID as the canonical lowercase hyphenated string.
@externTarget("System.Guid.ToString")
pub func hostGuidToString(g: in Uuid): String = ()

// Parse a UUID from any standard string format.
// Returns true and writes the parsed UUID on success; false otherwise.
@externTarget("System.Guid.TryParse")
pub func hostTryParseGuid(s: in String, value: out Uuid): Bool = ()
