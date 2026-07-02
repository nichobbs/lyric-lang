//! Llvm.Kernel — audited host boundary for the LLVM native backend.
//!
//! The LLVM backend emits textual `.ll` IR, so unlike `Msil.Kernel` /
//! `Jvm.Kernel` it needs no byte buffer.  Its only host boundary is the
//! IEEE-754 bit extraction used to render floating-point constants: LLVM
//! textual IR requires float constants to be bit-exact, and the only
//! always-exact spelling is the 0x-prefixed 16-hex-digit form of the raw
//! double bits, so the serialiser needs the bits of a `Double`.
package Llvm.Kernel

import Std.Core

@externTarget("System.BitConverter.DoubleToInt64Bits")
pub func doubleToInt64Bits(v: in Double): Long = ()
