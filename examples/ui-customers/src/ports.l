//! Customers.Ports — what the screens need from the outside world.
//!
//! Layer: ports.  Interfaces only; implementations live in the composition
//! layer (`Customers.Store` for the in-memory demo store).
@runtime_checked
package Customers.Ports

import Std.Core
import Customers.Domain.{Customer, CustomerId}

pub interface CustomerRepository {
  async func find(id: in CustomerId): Result[Customer, String]
  async func save(c: in Customer): Result[Customer, String]
  async func all(): Result[List[Customer], String]
}
