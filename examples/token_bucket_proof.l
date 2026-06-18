@proof_required
package TokenBucketProof

// Proof-focused token bucket demonstrating protected type invariant
// reasoning.  The time-based refill from Example 2 is simplified:
// `refill` takes `added: Double` as an explicit parameter so the
// verifier can reason about it without modelling Instant / Duration.
//
// Run with:
//
//     lyric prove examples/token_bucket_proof.l --verbose
//
// All obligations discharge under z3 (set LYRIC_Z3 or put z3 on $PATH).
// Without a solver, arithmetic goals go Unknown; pass --allow-unverified
// to suppress V0007 in that case.
//
// Invariant:  tokens >= 0.0  AND  tokens <= capacity
//
// Proof sketch:
//   tryAcquire: the if-branch only executes when `tokens >= count`;
//     `tokens := tokens - count` keeps tokens in [0, capacity] because
//     count > 0 and tokens was in [0, capacity].
//   refill: `tokens := min(tokens + added, capacity)` keeps tokens
//     in [0, capacity] because tokens + added >= tokens >= 0 and the
//     cap clamps to capacity.
//   make:  initial tokens == capacity, so the invariant holds from
//     construction.

pub protected type Bucket {
  var tokens: Double
  let capacity: Double

  invariant: tokens >= 0.0
  invariant: tokens <= capacity

  // Attempt to consume `count` tokens.  Returns true on success,
  // leaving the bucket with `count` fewer tokens; returns false
  // (no mutation) when insufficient tokens are available.
  pub entry tryAcquire(count: in Double): Bool
    requires: count > 0.0
    requires: count <= capacity
  {
    if tokens >= count {
      tokens = tokens - count
      assert(tokens >= 0.0)
      assert(tokens <= capacity)
      return true
    }
    return false
  }

  // Add `added` tokens, capped at capacity.
  pub entry refill(added: in Double): Unit
    requires: added > 0.0
  {
    val newTokens = tokens + added
    tokens = if newTokens > capacity then capacity else newTokens
    assert(tokens >= 0.0)
    assert(tokens <= capacity)
  }
}

// Construct a full bucket.  The postcondition records that the initial
// token count equals the capacity, satisfying the invariant at construction.
pub func make(capacity: in Double): Bucket
  requires: capacity > 0.0
  ensures:  result.tokens == capacity
  ensures:  result.capacity == capacity
{
  return Bucket(tokens = capacity, capacity = capacity)
}
