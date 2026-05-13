# Benchmarking

Performance work without measurement is guesswork. Lyric provides `lyric bench` to measure how long your functions take, with minimal friction: annotate the functions you want to measure, run one command, read the numbers. No external harness, no benchmark framework to install, no configuration files to write.

This chapter covers how to write a benchmark module, how to interpret the output, how to control the experiment with `--runs`, `--warmup`, and `--filter`, and what pitfalls to avoid so your numbers reflect reality.

::: note
**Bootstrap status (v1).** `lyric bench` runs on the .NET target today. JVM target support (via `--target jvm`) follows the JVM emit pipeline and is tracked as a v2 item. The `.NET` timings use `Std.Time.now()` / `since()` / `totalMillis()` backed by `System.Diagnostics.Stopwatch`, which measures wall-clock time to the nearest microsecond on most hosts.
:::

## §28.1 Anatomy of a benchmark module

A benchmark file looks like a normal Lyric source file with two additions: a `@bench_module` file-level annotation and one or more `@bench`-annotated functions.

```lyric
@bench_module
package Bench.Numeric

import Std.Core
import Std.Time

@bench
pub func benchIntSum(): Unit {
  var acc = 0
  var i   = 0
  while i < 65536 {
    acc = acc + i
    i   = i + 1
  }
  if acc < 0 { println(toString(acc)) }
}
```

**`@bench_module`** at the file level tells `lyric bench` that this file is a benchmark suite. Without it the command refuses to run (exit code B0900). The annotation does not affect `lyric build` or `lyric run` — benchmark files are not included in production packages.

**`@bench`** on a function marks it as a benchmark entry point. Only `pub func name(): Unit` functions are valid targets. The function must return `Unit` and take no parameters. Any helper functions in the file that are not annotated `@bench` run normally as part of the benchmark body but are not timed individually.

**`import Std.Time`** is required by the synthesised harness. If you omit it, `lyric bench` injects the import automatically.

## §28.2 Running a benchmark file

```sh
lyric bench benchmarks/bench_numeric.l
```

This compiles a timing harness around every `@bench` function, runs 10 timed iterations per benchmark (preceded by 3 warmup iterations), and prints results to stdout:

```
benchmark  runs=10  warmup=3

benchIntSum        min=0.068ms  max=0.091ms  mean=0.073ms
benchIntMulAcc     min=0.011ms  max=0.013ms  mean=0.011ms
benchGcd           min=0.481ms  max=0.543ms  mean=0.498ms
benchDoubleSum     min=1.219ms  max=1.254ms  mean=1.231ms
benchFibRecursive  min=5.501ms  max=6.127ms  mean=5.632ms
```

The output is line-oriented and machine-readable: each benchmark line is `name  min=Xms  max=Xms  mean=Xms`.

### Controlling the run

| Flag | Default | Meaning |
|---|---|---|
| `--runs N` | `10` | Number of *timed* iterations per benchmark |
| `--warmup N` | `3` | Number of un-timed warmup iterations (JIT, cache priming) |
| `--filter s` | *(all)* | Only run benchmarks whose name contains substring `s` |

```sh
# Quick sanity check — one run, no warmup.
lyric bench bench_numeric.l --runs 1 --warmup 0

# More stable mean — 50 timed iterations.
lyric bench bench_numeric.l --runs 50

# Only the Fibonacci benchmark.
lyric bench bench_numeric.l --filter Fib
```

Always use at least a few warmup iterations. Without warmup, the first run triggers JIT compilation of the inner loop, which inflates the `min` and distorts the `mean`.

## §28.3 Writing good benchmarks

### Keep the work proportional and explicit

The benchmark body should do a fixed, meaningful amount of work. A loop that runs a thousand times is more representative than calling a function once. Choose loop bounds that make the function take at least a few hundred microseconds — otherwise timer resolution noise dominates.

```lyric
@bench
pub func benchStringConcat(): Unit {
  var acc = ""
  var i   = 0
  while i < 1000 {
    acc = acc + "x"
    i   = i + 1
  }
  if acc.length < 0 { println(acc) }   // prevent dead-code elimination
}
```

### Defeat dead-code elimination

The .NET JIT may eliminate work whose result is never observed. The standard pattern is to guard a `println` on an impossible condition:

```lyric
if acc < 0 { println(toString(acc)) }
```

This forces `acc` to be live without actually printing anything (the condition is never true for reasonable inputs). The alternative is to return the accumulated value from the function, but since `@bench` functions must return `Unit`, the guard idiom is the idiomatic choice.

### Stay within `Int` range

Lyric's `Int` is a 32-bit signed integer with overflow-checked arithmetic (`Add_Ovf`, `Mul_Ovf`). An accumulator that exceeds `2_147_483_647` raises `OverflowException` at runtime. Choose loop bounds accordingly:

| Accumulation | Safe upper bound |
|---|---|
| `acc = acc + i` (linear) | `i < 65_536` (sum ≈ 2.1 billion) |
| `acc = acc + i * i` (quadratic) | `i <= 1_000` (sum ≈ 333 million) |
| `acc = acc + f(i)` where `f` is bounded by `B` | `i < 2_000_000_000 / B` |

If you need loops with larger counts, accumulate into a `Double` instead:

```lyric
@bench
pub func benchDoubleSum(): Unit {
  var acc = 0.0
  var i   = 0
  while i < 1000000 {
    acc = acc + 1.0
    i   = i + 1
  }
  if acc < 0.0 { println(toString(acc)) }
}
```

`Double` arithmetic uses non-overflow opcodes and can accumulate freely.

### Include helpers in the same file

Benchmark files may contain non-annotated helper functions. They participate in the same compilation unit and are inlined or optimised by the JIT alongside the benchmark body. This is intentional: you want the JIT to see the whole picture, just as your production code would.

```lyric
func gcd(a: in Int, b: in Int): Int {
  var x = a
  var y = b
  while y != 0 {
    val t = y
    y = x - (x / y) * y
    x = t
  }
  x
}

@bench
pub func benchGcd(): Unit {
  var result = 0
  var i = 1
  while i <= 10000 {
    result = gcd(result + i * 97 + 7, i * 89 + 3)
    i = i + 1
  }
  if result < 0 { println(toString(result)) }
}
```

## §28.4 What to benchmark

Good candidates for benchmarking are operations where performance matters and the cost is not obvious from inspection. Some categories worth measuring in most applications:

**Numeric kernels.** Integer loops, floating-point accumulation, and recursive arithmetic reveal the raw overhead of the JIT's compiled code and the cost of Lyric's overflow checking relative to unchecked arithmetic.

**Collection throughput.** `List` and `Map` operations stress allocation rate and GC pressure. Building a list of 10 000 elements and immediately traversing it together give you a picture of the GC's young-generation cost:

```lyric
@bench
pub func benchListBuild(): Unit {
  var lst: List[Int] = newList()
  var i = 0
  while i < 10000 {
    lst.add(i)
    i = i + 1
  }
  if lst.count < 0 { println(toString(lst.count)) }
}
```

**Contract overhead.** The `@runtime_checked` annotation injects requires/ensures assertions on every call. Comparing a plain function, a `@runtime_checked` variant, and an `@axiom` variant performing identical arithmetic isolates the assertion cost:

```lyric
func clampPlain(x: in Int, lo: in Int, hi: in Int): Int {
  if x < lo { return lo }
  if x > hi { return hi }
  x
}

@runtime_checked
func clampChecked(x: in Int, lo: in Int, hi: in Int): Int
  requires: lo <= hi
  ensures:  result >= lo and result <= hi
{
  if x < lo { return lo }
  if x > hi { return hi }
  x
}

@axiom("satisfies lo<=hi by construction")
func clampAxiom(x: in Int, lo: in Int, hi: in Int): Int {
  if x < lo { return lo }
  if x > hi { return hi }
  x
}

@bench pub func benchPlain():         Unit { /* call clampPlain   10 000× */ }
@bench pub func benchRuntimeChecked(): Unit { /* call clampChecked 10 000× */ }
@bench pub func benchAxiom():         Unit { /* call clampAxiom   10 000× */ }
```

**String operations.** Repeated concatenation with `+` on immutable strings is the worst case for an immutable string model (each concatenation allocates). If your benchmarks show a high fraction of time spent in `benchStringConcat`, a `StringBuilder`-style pattern or pre-allocated buffer pays off.

## §28.5 Interpreting the output

### Minimum, maximum, and mean

The harness reports three statistics per benchmark:

- **`min`** — the fastest observed run. If your JIT is working well, most runs converge near the minimum once the code is fully optimised. A min that is notably lower than the mean suggests GC pauses or OS scheduling jitter in the slower runs.

- **`max`** — the slowest run. A large gap between min and max (e.g., `min=0.07ms max=0.5ms`) usually indicates GC pauses, OS scheduling interrupts, or the first post-warmup run catching late JIT work. Increase `--warmup` to push late JIT out of the timed region.

- **`mean`** — the arithmetic mean of all timed runs. The mean is the right number to compare across versions when you have enough runs (≥ 10) and a stable `max` (low jitter).

### Sources of noise

| Noise source | Symptom | Mitigation |
|---|---|---|
| JIT compilation | High `max` on first few timed runs | Increase `--warmup` |
| GC pauses | Occasional high `max` despite warmup | Reduce allocation in the benchmark body; separate alloc-heavy and alloc-free benchmarks |
| OS scheduling | Random high outliers | Increase `--runs` to average out; run on a quiet host |
| Timer resolution | Min near zero for very fast benchmarks | Make the loop body do more work |

### When to trust the numbers

Trust benchmark numbers when:

- The `--warmup` is large enough that `min` is stable across multiple `lyric bench` invocations.
- The `max / min` ratio is small (ideally ≤ 2×).
- You are comparing two versions of the same benchmark (same loop structure, same loop count, same anti-elimination guard).

Do not compare absolute times across different machines or .NET versions. Do compare *relative* performance — how much faster is the `@axiom` variant than the `@runtime_checked` variant on *this* machine?

## §28.6 The benchmark files

The `benchmarks/` directory in the repository contains four ready-to-run suites:

| File | What it measures |
|---|---|
| `bench_numeric.l` | Integer sum, multiply-accumulate, GCD, double sum, recursive Fibonacci |
| `bench_collections.l` | List build, traversal, build+sum; Map insert and insert+lookup |
| `bench_contracts.l` | Plain vs `@runtime_checked` vs `@axiom` clamp function |
| `bench_string.l` | Repeated concatenation, `toString`, `.length`, `Str.contains`, `Str.replace` |

Run them all as a baseline when you start performance work:

```sh
lyric bench benchmarks/bench_numeric.l     --runs 20
lyric bench benchmarks/bench_collections.l --runs 20
lyric bench benchmarks/bench_contracts.l   --runs 20
lyric bench benchmarks/bench_string.l      --runs 20
```

Keep a copy of the numbers before and after your change. The ratio is what matters, not the absolute milliseconds.

## §28.7 Cross-target comparison

The JVM target (`--target jvm`) is on the roadmap for `lyric bench`. When it lands, the same benchmark file will run on both runtimes:

```sh
lyric bench benchmarks/bench_numeric.l --target dotnet
lyric bench benchmarks/bench_numeric.l --target jvm
```

This will surface where .NET and the JVM JIT make different choices (float-point vectorisation, bounds-check elimination, inline depth) and guide decisions about which operations benefit from target-specific stdlib implementations. Today, `.NET`-only numbers are already useful for absolute performance work and for comparing contract strategies.

## Exercises

1. **Baseline your machine**

   Run each of the four benchmark files in `benchmarks/` with `--runs 20 --warmup 5`. Record the mean for every benchmark. Change nothing, run again five minutes later. How stable are the numbers? What is the largest ratio between the two runs?

2. **Isolate contract cost**

   Run `benchmarks/bench_contracts.l` with `--runs 50`. What is the mean ratio between `benchRuntimeChecked` and `benchPlain`? What is the ratio between `benchAxiom` and `benchPlain`? Are the `@axiom` and `@axiom`-plain deltas explained by the requires/ensures assertion code?

3. **Build your own benchmark**

   Write a `@bench_module` file that benchmarks two string-building strategies: (a) repeated `+` concatenation and (b) building a `List[String]` of fragments and joining them with `Str.join`. Measure both for 1 000 fragments of length 10. Which is faster? Is the gap what you expected?

4. **Warmup effect**

   Run `lyric bench benchmarks/bench_numeric.l --filter FibRecursive --runs 5 --warmup 0` and then `--warmup 5`. Compare `min` and `max`. How much does the missing warmup inflate the first-run cost?

5. **Filter workflow**

   You are investigating whether a change to your GCD implementation improves performance. Add a faster version of `gcd` to `bench_numeric.l` under a new function `gcdFast` with its own `@bench` wrapper. Use `--filter Gcd` to run only the two GCD benchmarks side by side. What do you observe?
