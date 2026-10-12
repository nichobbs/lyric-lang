//! A function that exists only with the non-default feature `extra`.
package P

@cfg(feature = "extra")
func extraLimit(): Int {
  1000
}
