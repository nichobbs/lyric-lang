//! std/_kernel_native/config_host.l -- native-target `config { }` readers
//! (docs/25, #7435).
//!
//! `--target native` lowers each field of a `config` block to a module-level
//! `val` whose initializer calls one of these readers (`Lyric.LlvmBridge`'s
//! `lowerConfigBlocksNative`), so the environment is read once, before `main`.
//! There is no `_kernel/` twin: dotnet and the JVM read the environment in the
//! static initializer they emit for the block.  The readers are the audited
//! lyric-rt boundary (`lyric_config.c`); each takes the env var name, the
//! field's "Block.field" label and, for a numeric field, the text of its range
//! (the G0004 message).  A value that is absent, malformed or out of range
//! stops startup with exit 78 inside the runtime.
//!
//! The flags are `Int` (0 or 1) rather than `Bool` to match the C signatures.
@axiom("config readers via lyric-rt conform to their documented contracts")
@io
package Std.ConfigHost

import Std.Core

extern func rtConfigInt(env: String, label: String, rangeDesc: String, hasDefault: Int, def: Int, hasMin: Int, lo: Long, hasMax: Int, hi: Long, upperExclusive: Int): Int = "lyric_config_int"

extern func rtConfigLong(env: String, label: String, rangeDesc: String, hasDefault: Int, def: Long, hasMin: Int, lo: Long, hasMax: Int, hi: Long, upperExclusive: Int): Long = "lyric_config_long"

extern func rtConfigDouble(env: String, label: String, rangeDesc: String, hasDefault: Int, def: Double, hasMin: Int, lo: Double, hasMax: Int, hi: Double, upperExclusive: Int): Double = "lyric_config_double"

extern func rtConfigFloat(env: String, label: String, rangeDesc: String, hasDefault: Int, def: Float, hasMin: Int, lo: Float, hasMax: Int, hi: Float, upperExclusive: Int): Float = "lyric_config_float"

extern func rtConfigBool(env: String, label: String, hasDefault: Int, def: Int): Int = "lyric_config_bool"

extern func rtConfigString(env: String, label: String, hasDefault: Int, def: String): String = "lyric_config_string"

pub func readInt(
  env: in String,
  label: in String,
  rangeDesc: in String,
  hasDefault: in Int,
  def: in Int,
  hasMin: in Int,
  lo: in Long,
  hasMax: in Int,
  hi: in Long,
  upperExclusive: in Int,
): Int {
  rtConfigInt(env, label, rangeDesc, hasDefault, def, hasMin, lo, hasMax, hi, upperExclusive)
}

pub func readLong(
  env: in String,
  label: in String,
  rangeDesc: in String,
  hasDefault: in Int,
  def: in Long,
  hasMin: in Int,
  lo: in Long,
  hasMax: in Int,
  hi: in Long,
  upperExclusive: in Int,
): Long {
  rtConfigLong(env, label, rangeDesc, hasDefault, def, hasMin, lo, hasMax, hi, upperExclusive)
}

pub func readDouble(
  env: in String,
  label: in String,
  rangeDesc: in String,
  hasDefault: in Int,
  def: in Double,
  hasMin: in Int,
  lo: in Double,
  hasMax: in Int,
  hi: in Double,
  upperExclusive: in Int,
): Double {
  rtConfigDouble(env, label, rangeDesc, hasDefault, def, hasMin, lo, hasMax, hi, upperExclusive)
}

pub func readFloat(
  env: in String,
  label: in String,
  rangeDesc: in String,
  hasDefault: in Int,
  def: in Float,
  hasMin: in Int,
  lo: in Float,
  hasMax: in Int,
  hi: in Float,
  upperExclusive: in Int,
): Float {
  rtConfigFloat(env, label, rangeDesc, hasDefault, def, hasMin, lo, hasMax, hi, upperExclusive)
}

pub func readBool(env: in String, label: in String, hasDefault: in Int, def: in Int): Bool {
  rtConfigBool(env, label, hasDefault, def) != 0
}

pub func readString(env: in String, label: in String, hasDefault: in Int, def: in String): String {
  rtConfigString(env, label, hasDefault, def)
}
