//! Customers.Domain — the customer domain type and its form support
//! (docs/65-ui-library-sketch.md §3.1, §11).
//!
//! Layer: domain.  No UI, no I/O: imports only `Std.*` pure packages.
//!
//! `@generate(Forms.Derive)` derives the customer form (D151): the
//! `CustomerDraft` record, the `CustomerField` enum, `customerSchema()`,
//! `emptyCustomerDraft()`, `toCustomerDraft`, `customerDraftValue`,
//! `setCustomerField` and `validateCustomer`.
@runtime_checked
package Customers.Domain

import Std.Core

pub type CustomerId = Long range 1 ..= 9_999_999

pub type CreditLimit = Long range 0 ..= 1_000_000

pub enum Tier {
  case Standard
  case Preferred
  @label("Key account")
  case Key
}

pub func tierLabel(t: in Tier): String {
  return match t { case Standard -> "Standard"; case Preferred -> "Preferred"; case Key -> "Key account" }
}

/// A customer.  Key accounts must carry a credit limit of at least 10,000;
/// the form reports a violation as a form-level message rather than failing
/// construction (docs/65 §11.4).
@generate(Forms.Derive)
pub record Customer {
  @readonly
  id: CustomerId
  @maxLength(100)
  name: String
  @email
  email: String
  creditLimit: CreditLimit
  tier: Tier
  @multiline
  @maxLength(2000)
  notes: Option[String]
  invariant: keyAccountLimitOk(tier, creditLimit) @message("Key accounts need a credit limit of at least 10000")
}

/// The key-account rule, shared by the invariant and by any code that needs
/// to check it.
pub func keyAccountLimitOk(tier: in Tier, limit: in CreditLimit): Bool {
  return match tier { case Key -> limit.toLong() >= 10_000; case _ -> true }
}
