//! A package no other package imports, with a type error.
package Unreached

pub func broken(): Int {
  "not an int"
}
