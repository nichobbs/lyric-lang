# docs/70 phase 3a: a Never function used as a function of another result (D499)

A function value returning `Never` (a diverging lambda) passed or assigned where a function with the same parameters and another result is expected builds as a `CvNeverFn` conversion instead of being counted as an argument conversion (I0002).
