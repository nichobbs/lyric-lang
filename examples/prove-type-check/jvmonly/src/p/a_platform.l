//! A function that exists only in a `--target jvm` build.
package P

@cfg(target = "jvm")
func platformLimit(): Int {
  1000
}
