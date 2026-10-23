# D210 - A call that resolves through default arguments binds the overload that fills the fewest defaults

**Status:** accepted, implemented (#8355). Decided by the repo owner 2026-10-23.

## Context

`func f(x: in Int, y: in Int = 1)` and `func f(x: in Int, y: in Int = 10,
z: in Int = 100)` are two overloads, and `f(a)` fits both. The type checker
kept one `sigs[name]` slot per name, so the call bound whichever overload was
declared last: no rule, and with differing return types a T0070 against the
last declaration. The dotnet backend looked the callee up by the number of
arguments written, found neither overload under `f/1`, took the other
overload's token and emitted invalid IL (`InvalidProgramException`).

## Decision

A call binds a declaration by these rules, in this order:

1. A declaration the call fits is a candidate: every parameter the call leaves
   out has a default, each named argument names one of its parameters, and
   the arguments' types satisfy its parameters.
2. A candidate whose whole parameter list the arguments supply (no default
   used) wins.
3. A named argument narrows the candidates: a name only one candidate has
   selects it.
4. Among the rest, the candidate that fills the fewest defaults wins.
5. If two or more candidates still tie, the call is **T0200**, an ambiguity
   error whose hint is to name an argument only one of them declares (or to
   supply the parameters of the one meant).

Where the rule is silent it keeps what was already true: between candidates
that leave the same number of parameters to defaults, a non-generic
declaration is preferred to a generic one; a call supplying every parameter of
several declarations (the stdlib's `toUpper(Char)` and `toUpper(String)`)
keeps the first by registration order; a user definition shadows an imported
one; and the lowest import tier that declares a fitting candidate decides.

A method of the type answers a method call before a dot-named function of the
same shape, as D181 already says, so that pair is not a tie. Two candidates
fill the same number of defaults only when they declare the same number of
parameters; the language already rejects that within a package (T0001, T0162)
and for a bare name two imports declare (T0123, which still comes first and
asks for a qualified call), so T0200 reports what those leave, such as the
same-named methods of two `impl` blocks of one type (also T0139).

The rule applies to free functions (bare and package-qualified), record,
`impl` and interface methods, dot-named (UFCS) functions called as methods or
through their type, and generic overloads.

## Consumers

The type checker decides (`pickByShape`, `resolveMethodCallPick`) and records
the declaration's parameter count for the call site in
`SymbolTable.methodCallArities`, the table method calls already use (#7828).
`Lyric.Mono`, the MSIL and JVM backends and the native backend look the callee
up by that count instead of by the arguments written, so every backend runs
the declaration the checker chose and splices its defaults.

`Lyric.Parser.callDefaultsFilled` and `fewestDefaultsCandidates` are the
shared, type-blind form of the rule (how many parameters a call leaves to
defaults; which declarations leave the fewest). The checks that see calls
without types apply it conservatively, because the argument types can move
the checker's choice between declarations that fit:

- the mode checker (V0002) and the stability check (S0001) take every
  declaration the call fits as reachable;
- the verifier resolves a call only when exactly one declaration fits it and
  fails closed otherwise.

## Consequences

- A program with default-filling overloads no longer depends on declaration
  order, and the dotnet `InvalidProgramException` is gone.
- Generic overloads of one name and different arity get the right declaration
  from the checker, but dotnet cannot build them yet (#8461).
