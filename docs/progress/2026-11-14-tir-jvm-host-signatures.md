# 2026-11-14 - TIR: JVM host member signatures and the host conversions they need (D468)

docs/70 §6.2, #8613. The JVM resolver answers member signatures whose results are arrays, `float` or `short`; a `String` passes for a host supertype; any slice passes for a host array; a host call the checker settles at a supertype takes an upcast. Over the four stdlib JVM tests the kinds "host metadata cannot resolve" went 16 to 0 and "no host overload fits" 9 to 6, I0003 stays 0. Lambdas for host functional interfaces and records implementing extern interfaces are the remaining six.
