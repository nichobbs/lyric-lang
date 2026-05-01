// std/collections.l - Bootstrap-grade growable lists and hash maps.
//
// Lyric doesn't yet expose user-defined generic types across the FFI
// boundary, so each element / key / value type combination is its own
// concrete CLR class on the host side and its own opaque `extern type`
// here.  When generics-over-FFI lands these collapse to a single
// `List[T]` / `Map[K, V]`.
//
// Function signatures use `in` for the receiver — the underlying
// `Lyric.Stdlib.IntList` etc. are reference types, so passing them by
// borrow-style mutates the caller's value (this is the same trick
// `Std.File`'s host classes rely on).
//
// Naming: each operation is suffixed with the element/key/value type
// (`addInt`, `getStringInt`, `keysStringStringMap`) until the user has
// generics; this is verbose but unambiguous and survives intersecting
// imports without collisions.
package Std.Collections

// =====================================================================
// IntList — growable list of Int.
// =====================================================================

extern type IntList = "Lyric.Stdlib.IntList"

@externTarget("Lyric.Stdlib.IntList.New")
pub func newIntList(): IntList = ()

@externTarget("Lyric.Stdlib.IntList.Add")
pub func addInt(xs: in IntList, x: in Int): Unit = ()

@externTarget("Lyric.Stdlib.IntList.Get")
pub func getInt(xs: in IntList, i: in Int): Int = ()

@externTarget("Lyric.Stdlib.IntList.Set")
pub func setInt(xs: in IntList, i: in Int, x: in Int): Unit = ()

@externTarget("Lyric.Stdlib.IntList.Length")
pub func intListLength(xs: in IntList): Int = ()

@externTarget("Lyric.Stdlib.IntList.HasItem")
pub func intListContains(xs: in IntList, x: in Int): Bool = ()

@externTarget("Lyric.Stdlib.IntList.RemoveAt")
pub func intListRemoveAt(xs: in IntList, i: in Int): Unit = ()

@externTarget("Lyric.Stdlib.IntList.Clear")
pub func intListClear(xs: in IntList): Unit = ()

@externTarget("Lyric.Stdlib.IntList.ToArr")
pub func intListToSlice(xs: in IntList): slice[Int] = ()

// =====================================================================
// StringList — growable list of String.
// =====================================================================

extern type StringList = "Lyric.Stdlib.StringList"

@externTarget("Lyric.Stdlib.StringList.New")
pub func newStringList(): StringList = ()

@externTarget("Lyric.Stdlib.StringList.Add")
pub func addString(xs: in StringList, x: in String): Unit = ()

@externTarget("Lyric.Stdlib.StringList.Get")
pub func getString(xs: in StringList, i: in Int): String = ()

@externTarget("Lyric.Stdlib.StringList.Set")
pub func setString(xs: in StringList, i: in Int, x: in String): Unit = ()

@externTarget("Lyric.Stdlib.StringList.Length")
pub func stringListLength(xs: in StringList): Int = ()

@externTarget("Lyric.Stdlib.StringList.HasItem")
pub func stringListContains(xs: in StringList, x: in String): Bool = ()

@externTarget("Lyric.Stdlib.StringList.RemoveAt")
pub func stringListRemoveAt(xs: in StringList, i: in Int): Unit = ()

@externTarget("Lyric.Stdlib.StringList.Clear")
pub func stringListClear(xs: in StringList): Unit = ()

@externTarget("Lyric.Stdlib.StringList.ToArr")
pub func stringListToSlice(xs: in StringList): slice[String] = ()

// =====================================================================
// LongList — growable list of Long.
// =====================================================================

extern type LongList = "Lyric.Stdlib.LongList"

@externTarget("Lyric.Stdlib.LongList.New")
pub func newLongList(): LongList = ()

@externTarget("Lyric.Stdlib.LongList.Add")
pub func addLong(xs: in LongList, x: in Long): Unit = ()

@externTarget("Lyric.Stdlib.LongList.Get")
pub func getLong(xs: in LongList, i: in Int): Long = ()

@externTarget("Lyric.Stdlib.LongList.Set")
pub func setLong(xs: in LongList, i: in Int, x: in Long): Unit = ()

@externTarget("Lyric.Stdlib.LongList.Length")
pub func longListLength(xs: in LongList): Int = ()

@externTarget("Lyric.Stdlib.LongList.HasItem")
pub func longListContains(xs: in LongList, x: in Long): Bool = ()

@externTarget("Lyric.Stdlib.LongList.RemoveAt")
pub func longListRemoveAt(xs: in LongList, i: in Int): Unit = ()

@externTarget("Lyric.Stdlib.LongList.Clear")
pub func longListClear(xs: in LongList): Unit = ()

@externTarget("Lyric.Stdlib.LongList.ToArr")
pub func longListToSlice(xs: in LongList): slice[Long] = ()

// =====================================================================
// StringIntMap — hash map String -> Int.
//
// The host's `Get` returns 0 for a missing key — callers must gate on
// `containsKey` first (Lyric has no out-params, so this is the
// bootstrap workaround; same shape as `Std.Parse`).
// =====================================================================

extern type StringIntMap = "Lyric.Stdlib.StringIntMap"

@externTarget("Lyric.Stdlib.StringIntMap.New")
pub func newStringIntMap(): StringIntMap = ()

@externTarget("Lyric.Stdlib.StringIntMap.Put")
pub func putStringInt(m: in StringIntMap, key: in String, value: in Int): Unit = ()

@externTarget("Lyric.Stdlib.StringIntMap.Has")
pub func hasStringIntKey(m: in StringIntMap, key: in String): Bool = ()

@externTarget("Lyric.Stdlib.StringIntMap.Get")
pub func getStringIntRaw(m: in StringIntMap, key: in String): Int = ()

@externTarget("Lyric.Stdlib.StringIntMap.RemoveKey")
pub func removeStringIntKey(m: in StringIntMap, key: in String): Bool = ()

@externTarget("Lyric.Stdlib.StringIntMap.Length")
pub func stringIntMapLength(m: in StringIntMap): Int = ()

@externTarget("Lyric.Stdlib.StringIntMap.Clear")
pub func stringIntMapClear(m: in StringIntMap): Unit = ()

@externTarget("Lyric.Stdlib.StringIntMap.Keys")
pub func keysStringIntMap(m: in StringIntMap): slice[String] = ()

// =====================================================================
// StringStringMap — hash map String -> String.
// =====================================================================

extern type StringStringMap = "Lyric.Stdlib.StringStringMap"

@externTarget("Lyric.Stdlib.StringStringMap.New")
pub func newStringStringMap(): StringStringMap = ()

@externTarget("Lyric.Stdlib.StringStringMap.Put")
pub func putStringString(m: in StringStringMap, key: in String, value: in String): Unit = ()

@externTarget("Lyric.Stdlib.StringStringMap.Has")
pub func hasStringStringKey(m: in StringStringMap, key: in String): Bool = ()

@externTarget("Lyric.Stdlib.StringStringMap.Get")
pub func getStringStringRaw(m: in StringStringMap, key: in String): String = ()

@externTarget("Lyric.Stdlib.StringStringMap.RemoveKey")
pub func removeStringStringKey(m: in StringStringMap, key: in String): Bool = ()

@externTarget("Lyric.Stdlib.StringStringMap.Length")
pub func stringStringMapLength(m: in StringStringMap): Int = ()

@externTarget("Lyric.Stdlib.StringStringMap.Clear")
pub func stringStringMapClear(m: in StringStringMap): Unit = ()

@externTarget("Lyric.Stdlib.StringStringMap.Keys")
pub func keysStringStringMap(m: in StringStringMap): slice[String] = ()
