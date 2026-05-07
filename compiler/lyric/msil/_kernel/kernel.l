package Msil.Kernel

import Std.Core
import Std.Collections

extern type ByteWriter = "Lyric.Jvm.Hosts.JvmByteBuilder"

@externTarget("Lyric.Jvm.Hosts.JvmByteHost.New")
pub func bufNew(): ByteWriter = ()

@externTarget("Lyric.Jvm.Hosts.JvmByteHost.AppendByte")
pub func bufU1(w: in ByteWriter, v: in Int): Unit = ()

@externTarget("Lyric.Jvm.Hosts.JvmByteHost.AppendU2Le")
pub func bufU2(w: in ByteWriter, v: in Int): Unit = ()

@externTarget("Lyric.Jvm.Hosts.JvmByteHost.AppendU4Le")
pub func bufU4(w: in ByteWriter, v: in Int): Unit = ()

@externTarget("Lyric.Jvm.Hosts.JvmByteHost.AppendWriter")
pub func bufAppend(w: in ByteWriter, src: in ByteWriter): Unit = ()

@externTarget("Lyric.Jvm.Hosts.JvmByteHost.Position")
pub func bufLen(w: in ByteWriter): Int = ()

@externTarget("Lyric.Jvm.Hosts.JvmByteHost.ToList")
pub func bufToList(w: in ByteWriter): List[Byte] = ()

pub func bufZero(w: in ByteWriter, n: in Int): Unit {
  var i = 0
  while i < n {
    bufU1(w, 0)
    i = i + 1
  }
}

// Pad w to the next multiple of `align` bytes.
pub func bufPadTo(w: in ByteWriter, align: in Int): Unit {
  val r = bufLen(w) % align
  if r != 0 {
    bufZero(w, align - r)
  }
}
