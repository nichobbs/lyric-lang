/// Phase 1 minimal standard library, exposed as a small set of static
/// methods that the emitter can target. Each method's CLR signature
/// matches the Lyric-side declaration that the emitter will eventually
/// inject into the symbol table:
///
///   func println(s: in String): Unit
///   func print  (s: in String): Unit
///   func expect (cond: in Bool, msg: in String): Unit
///   func assert (cond: in Bool): Unit
///   func panic  (msg: in String): Never
///
/// The emitter calls these by emitting `call void
/// [Lyric.Stdlib]Lyric.Stdlib.Console::Println(string)` etc. They are
/// deliberately thin wrappers over the BCL: the goal is to give the
/// emitter a stable, predictable target it can resolve at codegen
/// time, not to ship a real stdlib.
namespace Lyric.Stdlib

open System

/// Console output. The two methods correspond to Lyric's
/// `std.io.println` / `std.io.print`.
[<Sealed; AbstractClass>]
type Console private () =

    static member Println (s: string) : unit =
        System.Console.WriteLine(s)

    static member Print (s: string) : unit =
        System.Console.Write(s)

    /// `println` overload for non-string values — emits `ToString()`.
    /// Used when the emitter needs to format an integer, bool, etc.
    static member PrintlnAny (value: obj | null) : unit =
        match value with
        | null    -> System.Console.WriteLine("()")
        | nonNull -> System.Console.WriteLine(nonNull.ToString())

/// Contract / test-harness intrinsics. Lyric's `expect` / `assert`
/// raise on failure; in Phase 1 we wire both to a single
/// `LyricAssertionException` so callers can catch via the FFI.
///
/// Defined as a plain CLR class (not an F# `exception` declaration)
/// so the emitted PE can `newobj` it directly and so the runtime's
/// `ToString` produces a clean message — F#'s synthesised exception
/// types have a `Data0` representation that the persisted-assembly
/// metadata round-trip stumbles on.
type LyricAssertionException(message: string) =
    inherit System.Exception(message)

[<Sealed; AbstractClass>]
type Contracts private () =

    static member Expect (cond: bool, msg: string) : unit =
        if not cond then
            raise (LyricAssertionException(msg))

    static member Assert (cond: bool) : unit =
        if not cond then
            raise (LyricAssertionException("assertion failed"))

    /// `panic` returns `Never` in Lyric. From the CLR's perspective
    /// this is a throw-only method whose return type is `void` (the
    /// emitter will mark its Lyric type as Never).
    static member Panic (msg: string) : unit =
        raise (LyricAssertionException("panic: " + msg))
