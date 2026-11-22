# Builder: a lambda whose body ends in `try` (D690)

The `try` yields the lambda's result value as a function body's does, so a panicking `catch` has nothing to convert. Shape: `lambda_ending_in_try`.
