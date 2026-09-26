//! Customers.Domain — the customer domain type and its form support
//! (docs/65-ui-library-sketch.md §3.1, §11).
//!
//! Layer: domain.  No UI, no I/O: imports only `Std.*` pure packages and
//! `Forms`.
//!
//! Everything below the "Form support" rule is written by hand today and is
//! exactly what `@generate(Forms.Derive)` will emit for `Customer` once the
//! generator ships (docs/65 §11.6, phase U4); it doubles as that generator's
//! golden output.
@runtime_checked
package Customers.Domain

import Std.Core
import Std.String
import Forms
import Forms.{FieldError, FieldPath, FormSchema, FieldSpec, InputKind, CrossField, Choice, fieldPath}
import Forms.Parse

pub type CustomerId = Long range 1 ..= 9_999_999

pub type CreditLimit = Long range 0 ..= 1_000_000

pub enum Tier {
  case Standard
  case Preferred
  case Key
}

pub func tierName(t: in Tier): String {
  return match t { case Standard -> "standard"; case Preferred -> "preferred"; case Key -> "key" }
}

pub func tierLabel(t: in Tier): String {
  return match t { case Standard -> "Standard"; case Preferred -> "Preferred"; case Key -> "Key account" }
}

pub func parseTier(s: in String): Option[Tier] {
  if s == "standard" {
    return Some(value = Tier.Standard)
  }
  if s == "preferred" {
    return Some(value = Tier.Preferred)
  }
  if s == "key" {
    return Some(value = Tier.Key)
  }
  return None
}

/// A customer.  Key accounts must carry a credit limit of at least 10,000;
/// validation reports a violation as a form-level message rather than
/// failing construction (docs/65 §11.4).
pub record Customer {
  id: CustomerId
  name: String
  email: String
  creditLimit: CreditLimit
  tier: Tier
  notes: Option[String]
}

/// The key-account rule, shared by validation and by any code that needs to
/// check it.
pub func keyAccountLimitOk(tier: in Tier, limit: in CreditLimit): Bool {
  return match tier { case Key -> limit.toLong() >= 10_000; case _ -> true }
}

pub val keyAccountMessage: String = "Key accounts need a credit limit of at least 10000"

// ─── Form support (what @generate(Forms.Derive) will emit) ────────────────────
/// The editable draft of a `Customer`: raw text as typed.
pub record CustomerDraft {
  name: String
  email: String
  creditLimit: String
  tier: String
  notes: String
}

/// The editable fields of a `Customer`.
pub enum CustomerField {
  case Name
  case Email
  case CreditLimitField
  case TierField
  case Notes
}

/// The schema name of a field; `fieldPath(customerFieldName(f))` is the
/// path its `FieldError`s carry.
pub func customerFieldName(f: in CustomerField): String {
  return match f {
    case Name -> "name"
    case Email -> "email"
    case CreditLimitField -> "creditLimit"
    case TierField -> "tier"
    case Notes -> "notes"
  }
}

/// The field with schema name `name`.
pub func customerFieldNamed(name: in String): Option[CustomerField] {
  if name == "name" {
    return Some(value = CustomerField.Name)
  }
  if name == "email" {
    return Some(value = CustomerField.Email)
  }
  if name == "creditLimit" {
    return Some(value = CustomerField.CreditLimitField)
  }
  if name == "tier" {
    return Some(value = CustomerField.TierField)
  }
  if name == "notes" {
    return Some(value = CustomerField.Notes)
  }
  return None
}

pub func customerSchema(): FormSchema {
  val tiers: List[Choice] = newList()
  for t in [Tier.Standard, Tier.Preferred, Tier.Key] {
    tiers.add(Choice(value = tierName(t), label = tierLabel(t)))
  }
  val fs: List[FieldSpec] = newList()
  fs.add(Forms.maxLength(Forms.required(Forms.fieldSpec("name", "Name", InputKind.Text)), 100))
  fs.add(Forms.required(Forms.fieldSpec("email", "Email", InputKind.Email)))
  fs.add(Forms.bounded(Forms.required(Forms.fieldSpec("creditLimit", "Credit limit", InputKind.Number)), 0, 1_000_000))
  fs.add(Forms.withChoices(Forms.required(Forms.fieldSpec("tier", "Tier", InputKind.Select)), tiers))
  fs.add(Forms.maxLength(Forms.fieldSpec("notes", "Notes", InputKind.MultilineText), 2000))
  return Forms.schema(fs)
}

pub func emptyCustomerDraft(): CustomerDraft {
  return CustomerDraft(name = "", email = "", creditLimit = "0", tier = tierName(Tier.Standard), notes = "")
}

pub func toCustomerDraft(c: in Customer): CustomerDraft {
  val notes = match c.notes { case Some(n) -> n; case None -> "" }
  return CustomerDraft(
    name = c.name,
    email = c.email,
    creditLimit = c.creditLimit.toString(),
    tier = tierName(c.tier),
    notes = notes
  )
}

pub func customerDraftValue(d: in CustomerDraft, f: in CustomerField): String {
  return match f {
    case Name -> d.name
    case Email -> d.email
    case CreditLimitField -> d.creditLimit
    case TierField -> d.tier
    case Notes -> d.notes
  }
}

pub func setCustomerField(d: in CustomerDraft, f: in CustomerField, v: in String): CustomerDraft {
  return match f {
    case Name -> CustomerDraft(
      name = v,
      email = d.email,
      creditLimit = d.creditLimit,
      tier = d.tier,
      notes = d.notes
    )
    case Email -> CustomerDraft(
      name = d.name,
      email = v,
      creditLimit = d.creditLimit,
      tier = d.tier,
      notes = d.notes
    )
    case CreditLimitField -> CustomerDraft(
      name = d.name,
      email = d.email,
      creditLimit = v,
      tier = d.tier,
      notes = d.notes
    )
    case TierField -> CustomerDraft(
      name = d.name,
      email = d.email,
      creditLimit = d.creditLimit,
      tier = v,
      notes = d.notes
    )
    case Notes -> CustomerDraft(
      name = d.name,
      email = d.email,
      creditLimit = d.creditLimit,
      tier = d.tier,
      notes = v
    )
  }
}

/// The customer described by `d`, or every problem with it.
pub func validateCustomer(d: in CustomerDraft, id: in CustomerId): Result[Customer, List[FieldError]] {
  val errs: List[FieldError] = newList()
  val name = Parse.collect(errs, withinLength(fieldPath("name"), Parse.requiredText(fieldPath("name"), d.name), 100), "")
  val email = Parse.collect(errs, Parse.email(fieldPath("email"), d.email), "")
  val limit = Parse.collect(errs, Parse.longInRange(fieldPath("creditLimit"), d.creditLimit, 0, 1_000_000), 0)
  val tierText = Parse.collect(errs, Parse.oneOf(fieldPath("tier"), d.tier, tierNames()), "standard")
  val notesText = Parse.collect(errs, withinLength(fieldPath("notes"), Ok(value = d.notes), 2000), "")
  if errs.count > 0 {
    return Err(error = errs)
  }
  // `longInRange` checked the bounds, so the conversion cannot fail.
  val credit = CreditLimit.from(limit)
  val tier = match parseTier(tierText) { case Some(t) -> t; case None -> Tier.Standard }
  if not keyAccountLimitOk(tier, credit) {
    errs.add(CrossField(message = keyAccountMessage))
    return Err(error = errs)
  }
  return Ok(
    value = Customer(
      id = id,
      name = name,
      email = email,
      creditLimit = credit,
      tier = tier,
      notes = Parse.optionalText(notesText)
    )
  )
}

func tierNames(): List[String] {
  val acc: List[String] = newList()
  for t in [Tier.Standard, Tier.Preferred, Tier.Key] {
    acc.add(tierName(t))
  }
  return acc
}

func withinLength(field: in FieldPath, r: in Result[String, FieldError], max: in Int): Result[String, FieldError] {
  return match r { case Ok(s) -> Parse.withinLength(field, s, max); case Err(e) -> Err(error = e) }
}
