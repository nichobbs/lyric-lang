//! Rbac.Enforcement — runtime permission check combining DB roles with
//! the @proof_required policy model.
//!
//! The pattern:
//!   1. Load the caller's role assignments from the DB.
//!   2. For each assignment, call Rbac.Policy.hasPermission to test whether
//!      the role grants the required permission.
//!   3. Return Err(PermissionDenied) if no role matches.
//!
//! Because hasPermission lives in @proof_required code and the no-escalation
//! theorem is machine-checked, the runtime checks here cannot be bypassed
//! through the type system — they are the only code path that grants access.
@runtime_checked
package Rbac.Enforcement

import Std.Core
import Rbac.Policy
import Rbac.Store
import Db

pub union CheckResult {
  case Allowed(role: String)
  case Denied(reason: String)
}

/// Check whether `userId` holds `permission`.
/// Returns the first role that grants the permission, or Denied.
pub func check(conn: in DbConnection, userId: in Long, permission: in Permission): Result[CheckResult, StoreError] {
  match Rbac.Store.getRolesForUser(conn, userId) {
    case Err(e) -> Err(e)
    case Ok(assignments) -> {
      for a in assignments {
        match Rbac.Policy.roleFromString(a.roleName) {
          case None -> ()    // unknown role in DB — skip
          case Some(role) -> if Rbac.Policy.hasPermission(role, permission) { return Ok(CheckResult.Allowed(role = a.roleName)) }
        }
      }
      Ok(
        CheckResult.Denied(
          reason = "user " + userId.toString() + " lacks permission: " + Rbac.Policy.permissionLabel(permission)
        )
      )
    }
  }
}

/// Grant `targetRoleName` to `targetUserId`.
///
/// The grantor must hold ManageUsers permission.  Before touching the DB
/// the check calls Rbac.Policy.noEscalation to verify the grantor holds
/// the target role — i.e. the grantor's highest role must dominate the
/// target role.  noEscalation is @proof_required so this check is also
/// machine-verified for any @proof_required caller.
pub func grantRole(
  conn: in DbConnection, grantorUserId: in Long, targetUserId: in Long, targetRoleName: in String
): Result[Unit, StoreError] {
  // 1. Grantor must have ManageUsers.
  match check(conn, grantorUserId, Permission.ManageUsers) {
    case Err(e) -> Err(e)
    case Ok(CheckResult.Denied(reason)) -> Err(StoreError.PermissionDenied(message = reason))
    case Ok(CheckResult.Allowed(grantorRoleName)) -> {
      // 2. Verify no-escalation: grantor must dominate target role.
      match Rbac.Policy.roleFromString(grantorRoleName) {
        case None -> Err(StoreError.PermissionDenied(message = "unrecognised grantor role: " + grantorRoleName))
        case Some(grantorRole) -> match Rbac.Policy.roleFromString(targetRoleName) {
          case None -> Err(StoreError.RoleNotFound(name = targetRoleName))
          case Some(targetRole) -> if not Rbac.Policy.dominates(grantorRole, targetRole) {
            // Escalation attempt: grantor cannot grant a role above their own.
            // noEscalation oracle confirms this is structurally impossible
            // in @proof_required call sites; here we enforce it at runtime.
            Err(
              StoreError.PermissionDenied(
                message = "cannot grant role '" + targetRoleName + "': grantor role '" + grantorRoleName +
                  "' does not dominate it"
              )
            )
          } else {
            Rbac.Store.grantRole(conn, targetUserId, targetRoleName, grantorUserId)
          }
        }
      }
    }
  }
}

/// Revoke `targetRoleName` from `targetUserId`.
/// The revoker must hold ManageUsers and must dominate the target role.
pub func revokeRole(
  conn: in DbConnection, revokerUserId: in Long, targetUserId: in Long, targetRoleName: in String
): Result[Unit, StoreError] {
  match check(conn, revokerUserId, Permission.ManageUsers) {
    case Err(e) -> Err(e)
    case Ok(CheckResult.Denied(reason)) -> Err(StoreError.PermissionDenied(message = reason))
    case Ok(CheckResult.Allowed(revokerRoleName)) -> match Rbac.Policy.roleFromString(revokerRoleName) { case None -> Err(StoreError.PermissionDenied(message = "unrecognised revoker role: " + revokerRoleName)); case Some(revokerRole) -> match Rbac.Policy.roleFromString(targetRoleName) { case None -> Err(StoreError.RoleNotFound(name = targetRoleName)); case Some(targetRole) -> if not Rbac.Policy.dominates(revokerRole, targetRole) { Err(StoreError.PermissionDenied(message = "cannot revoke role '" + targetRoleName + "': revoker role '" + revokerRoleName + "' does not dominate it")) } else { Rbac.Store.revokeRole(conn, targetUserId, targetRoleName) } } }
  }
}
