# D535: module-level `val` reads lower from TIR on native

Status: accepted (docs/70 phase 4a, part 6; D520 slice 36).

## Decision

1. **A module-level `val` is read from TIR the way the AST path reads it.** The lowering of `XGlobal` (`lowerGlobal`, `llvm_tir.l`) looks the symbol up in `TirLowerEnv.globals`; a symbol it lacks is recorded in `needGlobals`, the lowering fails, and the code generator resolves it (`resolveTirGlobal`) and the lowering is tried again, as it is for `needFns`, tuple layouts and list types.
2. **Resolution is by the symbol's DefPath key** (`Pkg::name`, a config field `Pkg::Block::field`) into `ctx.moduleVals`:
   - a **literal initialiser** (`isLiteralInit`) that lowers to a constant without instructions is inlined as that constant;
   - a **plain string literal** is lowered at each read (`TirGlobalRef.hasText`, the TIR string-literal lowering);
   - any **other initialiser** is the hoisted `__lyric_mvinit_<name>` function: `registerModuleGlobal` (split out of `loadModuleGlobal`, so the AST and TIR reads share it) registers the static `mv.`/`mvf.` globals once, and a read is `call mvensure.<init>` then a load that borrows from the global, which owns the value for the life of the process.
3. A literal that needs instructions to build other than a plain string, a generic module value, and a symbol whose key the unit's names lack stay on the AST path with a census reason that names the value.

## Consequences

The census (20 suites) runs a module-level `val` through TIR for the first time, which exposed a TIR builder bug the AST fallback had hidden: the computed index of an `inout` array element is evaluated after later named arguments (D171, #9383). `inout_array_element_self_test.l` is listed as a known gap in `native-via-tir-census.sh` until the builder is fixed, as `named_arg_eval_order_self_test.l` was for #9076.

## Verification

`scripts/ci/native-via-tir/globals.l` (an `Int`, a `Long`, a `String`, a computed `Int` and a computed `String`) lowers 8 of 8 functions (six and two hoisted initialisers) from TIR with the AST path's output and is clean under AddressSanitizer.
