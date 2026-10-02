# Component-wise `derives Add, Sub` on homogeneous numeric records (docs/67 G1, #7940)

D155 extended derived arithmetic to *homogeneous numeric records*: a record
whose fields all have one numeric type (`record Vec3 { x: Float; y: Float;
z: Float }`) may derive `Add` and `Sub`, and `+`/`-` then apply field by
field. The checker already accepted `@derive(Add)` on records (it satisfies a
`where T: Add` bound), but no backend lowered `a + b` on one.

## Checking

- `@derive(Add)` / `@derive(Sub)` is allowed on a non-generic record with at
  least one field, no `invariant:`, and every field the same numeric
  primitive (`Byte`, `Int`, `Long`, `UInt`, `ULong`, `Nat`, `Float`,
  `Double`). `Mul`, `Div` and `Mod` on a record, and `Add`/`Sub` on any other
  shape, are the new **T0152**. A record with an invariant is excluded
  because the component-wise result is built field by field and would not
  pass through the invariant's checker.
- `a + b` / `a - b` on two values of such a record, and `r += s` / `r -= s`,
  record a `RecordArithSite` (constructor path, qualified when the record is
  imported; field names; the record's type; the operator). A compound
  assignment needs a variable or field target (T0134, as for distinct types).

## Lowering

`Lyric.ContractElaborator.lowerRecordArith`, run in the shared pipeline right
after the distinct-type operator pass, rewrites each site to

```lyric
{
  val __lyric_ra_<s>_<e>_l: R = a
  val __lyric_ra_<s>_<e>_r: R = b
  R(x = __l.x + __r.x, y = __l.y + __r.y, ...)
}
```

so each operand is evaluated once, left to right, and every backend receives
ordinary field reads and a constructor call. The temporaries are typed so the
JVM, which erases unannotated locals, can read the fields back. Contract
clauses are rewritten too.

## Verification

`lyric-compiler/lyric/record_arith_self_test.l` (7 cases: `Float` and `Int`
records, chaining, single evaluation of each operand, compound assignment,
`Byte` fields, a mutable record's sum being a new instance, and use in
an `ensures:` clause) passes on dotnet, JVM and native and runs in CI on all
three. A two-package project using an imported record's `+` without
importing the record's name was checked on all three targets.
`typechecker_self_test.l` covers T0152 and the T0134 target rule.

`+` on a type parameter bounded by `where T: Add` is still rejected inside the
generic body (T0030), for distinct types as for records; the bound only
constrains callers today (#7996).
