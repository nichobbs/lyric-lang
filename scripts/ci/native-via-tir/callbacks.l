//! callbacks.l - a Lyric closure passed to a C callback API (docs/70 phase 4a, D877): `pthread_create`'s start routine is the
//! ccc trampoline the TIR lowering synthesises (`CvCallback`), and the same closure rides along as the userdata pointer
//! (`CvClosureAsPointer`).  The worker allocates a C string on the second thread from a captured Lyric string; `main`
//! collects it through `pthread_join` and prints its length.  `native-via-tir-e2e.sh` requires every function from
//! TIR, the same output as the AST path, and a clean AddressSanitizer run.
package CallbacksViaTir

import Std.Core

extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = "pthread_create"

extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = "pthread_join"

extern func cStrlen(s: NativePtr[Byte]): Long = "strlen"

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

@unsafe_ffi
func runOnThread(msg: in String): Long {
  val worker: () -> NativePtr[Byte] = { -> toC(msg) }
  var tid: Long = 0
  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)
  if rc != 0 {
    return -1
  }
  var outp: NativePtr[Byte] = nativeNullPtr()
  val rj = pthreadJoin(tid, nativeAddrOf(outp))
  if rj != 0 {
    return -2
  }
  val n = cStrlen(outp)
  freeC(outp)
  n
}

func main(): Unit {
  println(toString(runOnThread("hello-from-thread")))
  println(toString(runOnThread("")))
  println(toString(runOnThread("0123456789")))
}
