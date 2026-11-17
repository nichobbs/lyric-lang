# docs/70 phase 3a: a Never function used as a Unit function (D499)

A function value returning `Never` passed or assigned where `func(...): Unit` with the same parameters is expected builds as a `CvNeverFnAsUnit` conversion instead of being counted as an argument conversion (I0002).
