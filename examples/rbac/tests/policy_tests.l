// tests/policy_tests.l — unit tests for Rbac.Policy.
//
// Covers the @proof_required permission model and machine-checked theorems.
// All tests are pure; no I/O.
//
// Run:  lyric test examples/rbac/tests/policy_tests.l

@test_module
package Rbac.PolicyTests

import Std.Core
import Std.Testing
import Rbac.Policy

// ─── roleLabel / roleFromString ───────────────────────────────────────────────

test "roleFromString parses guest" {
  match Rbac.Policy.roleFromString("guest") {
    case None    -> assertTrue(false, "should parse 'guest'")
    case Some(r) -> assertEqual(Rbac.Policy.roleLabel(r), "guest", "round-trip")
  }
}

test "roleFromString parses user" {
  match Rbac.Policy.roleFromString("user") {
    case None    -> assertTrue(false, "should parse 'user'")
    case Some(r) -> assertEqual(Rbac.Policy.roleLabel(r), "user", "round-trip")
  }
}

test "roleFromString parses manager" {
  match Rbac.Policy.roleFromString("manager") {
    case None    -> assertTrue(false, "should parse 'manager'")
    case Some(r) -> assertEqual(Rbac.Policy.roleLabel(r), "manager", "round-trip")
  }
}

test "roleFromString parses admin" {
  match Rbac.Policy.roleFromString("admin") {
    case None    -> assertTrue(false, "should parse 'admin'")
    case Some(r) -> assertEqual(Rbac.Policy.roleLabel(r), "admin", "round-trip")
  }
}

test "roleFromString returns None for unknown role" {
  assertTrue(isNone(Rbac.Policy.roleFromString("superuser")), "unknown → None")
}

// ─── roleLevel ────────────────────────────────────────────────────────────────

test "Admin has higher level than Manager" {
  assertTrue(Rbac.Policy.roleLevel(Role.Admin) > Rbac.Policy.roleLevel(Role.Manager),
    "Admin > Manager")
}

test "Manager has higher level than User" {
  assertTrue(Rbac.Policy.roleLevel(Role.Manager) > Rbac.Policy.roleLevel(Role.User),
    "Manager > User")
}

test "User has higher level than Guest" {
  assertTrue(Rbac.Policy.roleLevel(Role.User) > Rbac.Policy.roleLevel(Role.Guest),
    "User > Guest")
}

// ─── dominates ────────────────────────────────────────────────────────────────

test "Admin dominates all roles" {
  assertTrue(Rbac.Policy.dominates(Role.Admin, Role.Guest),   "Admin ≥ Guest")
  assertTrue(Rbac.Policy.dominates(Role.Admin, Role.User),    "Admin ≥ User")
  assertTrue(Rbac.Policy.dominates(Role.Admin, Role.Manager), "Admin ≥ Manager")
  assertTrue(Rbac.Policy.dominates(Role.Admin, Role.Admin),   "Admin ≥ Admin")
}

test "Guest does not dominate User" {
  assertTrue(not Rbac.Policy.dominates(Role.Guest, Role.User), "Guest < User")
}

test "User does not dominate Manager" {
  assertTrue(not Rbac.Policy.dominates(Role.User, Role.Manager), "User < Manager")
}

// ─── hasPermission ────────────────────────────────────────────────────────────

test "Admin holds all permissions" {
  assertTrue(Rbac.Policy.hasPermission(Role.Admin, Permission.Read),          "Admin: Read")
  assertTrue(Rbac.Policy.hasPermission(Role.Admin, Permission.Write),         "Admin: Write")
  assertTrue(Rbac.Policy.hasPermission(Role.Admin, Permission.Delete),        "Admin: Delete")
  assertTrue(Rbac.Policy.hasPermission(Role.Admin, Permission.ManageUsers),   "Admin: ManageUsers")
  assertTrue(Rbac.Policy.hasPermission(Role.Admin, Permission.AdministerAll), "Admin: AdministerAll")
}

test "Manager holds Read Write Delete ManageUsers but not AdministerAll" {
  assertTrue(Rbac.Policy.hasPermission(Role.Manager, Permission.Read),         "Manager: Read")
  assertTrue(Rbac.Policy.hasPermission(Role.Manager, Permission.Write),        "Manager: Write")
  assertTrue(Rbac.Policy.hasPermission(Role.Manager, Permission.Delete),       "Manager: Delete")
  assertTrue(Rbac.Policy.hasPermission(Role.Manager, Permission.ManageUsers),  "Manager: ManageUsers")
  assertTrue(not Rbac.Policy.hasPermission(Role.Manager, Permission.AdministerAll),
    "Manager lacks AdministerAll")
}

test "User holds Read and Write only" {
  assertTrue(Rbac.Policy.hasPermission(Role.User, Permission.Read),  "User: Read")
  assertTrue(Rbac.Policy.hasPermission(Role.User, Permission.Write), "User: Write")
  assertTrue(not Rbac.Policy.hasPermission(Role.User, Permission.Delete),
    "User lacks Delete")
  assertTrue(not Rbac.Policy.hasPermission(Role.User, Permission.ManageUsers),
    "User lacks ManageUsers")
}

test "Guest holds Read only" {
  assertTrue(Rbac.Policy.hasPermission(Role.Guest, Permission.Read), "Guest: Read")
  assertTrue(not Rbac.Policy.hasPermission(Role.Guest, Permission.Write),
    "Guest lacks Write")
  assertTrue(not Rbac.Policy.hasPermission(Role.Guest, Permission.Delete),
    "Guest lacks Delete")
}

// ─── dominanceTransitive (proof oracle) ──────────────────────────────────────
//
// dominanceTransitive is a proof oracle guaranteed to return true for
// all valid inputs.  Calling it with inputs violating requires: triggers
// a contract assertion rather than returning false.

test "dominanceTransitive holds Admin >= Manager >= User" {
  val ok = Rbac.Policy.dominanceTransitive(Role.Admin, Role.Manager, Role.User)
  assertTrue(ok, "Admin ≥ Manager ≥ User")
}

test "dominanceTransitive holds Admin >= Admin >= Guest" {
  val ok = Rbac.Policy.dominanceTransitive(Role.Admin, Role.Admin, Role.Guest)
  assertTrue(ok, "Admin ≥ Admin ≥ Guest")
}

test "dominanceTransitive holds Manager >= User >= Guest" {
  val ok = Rbac.Policy.dominanceTransitive(Role.Manager, Role.User, Role.Guest)
  assertTrue(ok, "Manager ≥ User ≥ Guest")
}

// ─── adminHoldsAll (proof oracle) ────────────────────────────────────────────

test "adminHoldsAll for Read" {
  assertTrue(Rbac.Policy.adminHoldsAll(Permission.Read), "Admin holds Read")
}

test "adminHoldsAll for AdministerAll" {
  assertTrue(Rbac.Policy.adminHoldsAll(Permission.AdministerAll),
    "Admin holds AdministerAll")
}

// ─── guestIsRestricted (proof oracle) ────────────────────────────────────────

test "guestIsRestricted for Write" {
  assertTrue(not Rbac.Policy.guestIsRestricted(Permission.Write),
    "Guest is restricted from Write")
}

test "guestIsRestricted for ManageUsers" {
  assertTrue(not Rbac.Policy.guestIsRestricted(Permission.ManageUsers),
    "Guest is restricted from ManageUsers")
}
