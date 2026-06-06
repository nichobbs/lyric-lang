package Msil.SelfTestM1

import Msil.Pe
import Msil.Kernel
import Std.Core
import Std.Collections

// Self-test M1: build a minimal "Hello" PE image and validate its structural
// invariants without executing the assembly.
//
// Checks performed:
//   pe_size_ok       — image is exactly 1024 bytes
//   mz_ok            — DOS MZ signature at bytes 0–1
//   pe_sig_ok        — "PE\0\0" signature at file offset 0x80
//   clr_header_ok    — CLR header size field = 72 at file offset 0x200
//   bsjb_ok          — BSJB metadata magic at file offset 0x254
func main(): Unit {
  // pe_size_ok: check size before converting to list (List[Byte].length is unavailable)
  val size = buildHelloAssemblySize()
  if size == 1024 {
    println("pe_size_ok=true")
  } else {
    println("pe_size_ok=false")
  }

  val bytes = buildHelloAssembly()

  // mz_ok: bytes[0]==0x4D and bytes[1]==0x5A
  val mzOk = bytes[0] == 0x4D and bytes[1] == 0x5A
  if mzOk {
    println("mz_ok=true")
  } else {
    println("mz_ok=false")
  }

  // pe_sig_ok: "PE\0\0" at offset 0x80
  val peSigOk = bytes[0x80] == 0x50 and bytes[0x81] == 0x45 and bytes[0x82] == 0x00 and bytes[0x83] == 0x00
  if peSigOk {
    println("pe_sig_ok=true")
  } else {
    println("pe_sig_ok=false")
  }

  // clr_header_ok: cb field (LE32) at 0x200 == 72
  val clrCbOk = bytes[0x200] == 72 and bytes[0x201] == 0 and bytes[0x202] == 0 and bytes[0x203] == 0
  if clrCbOk {
    println("clr_header_ok=true")
  } else {
    println("clr_header_ok=false")
  }

  // bsjb_ok: "BSJB" magic at offset 0x254
  val bsjbOk = bytes[0x254] == 0x42 and bytes[0x255] == 0x53 and bytes[0x256] == 0x4A and bytes[0x257] == 0x42
  if bsjbOk {
    println("bsjb_ok=true")
  } else {
    println("bsjb_ok=false")
  }
}
