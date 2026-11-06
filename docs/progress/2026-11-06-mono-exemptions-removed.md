# Mono's extern and no-position exemptions removed (D356)

The unpinned-call rule no longer exempts `@externTarget` generics or calls
without a source position. The checker judges extern generic calls (its own
package's included) and records the type arguments an expected type fixes, so
the monomorphiser reads them instead of guessing. The census (stage 2, 85
library builds, the examples) reported no call that needed an exemption. Mono's
one remaining exemption is a function value. Remaining in #8760: close the
issue.
