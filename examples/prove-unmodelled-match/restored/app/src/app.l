//! `HttpError` here is the dependency's, restored as a compiled assembly
//! whose declarations the verifier does not read; the standard library's
//! union of that name, which it does read, says nothing about it.  So the
//! bare `Zap` and `Zop` may be cases, the arms are not modelled, and the
//! postcondition (false for `Zop`) is not proved (#8230).
@proof_required
package App

import Mylib.{HttpError}

pub func f(e: in HttpError): Bool
  ensures: result
{
  match e {
    case Zap -> true
    case Zop -> false
  }
}
