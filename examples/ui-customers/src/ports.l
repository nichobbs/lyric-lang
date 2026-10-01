//! Customers.Ports — what the screens need from the outside world.
//!
//! Layer: ports.  Interfaces only; implementations live in the composition
//! layer (`Customers.Store` for the in-memory demo store).
@runtime_checked
package Customers.Ports

import Std.Core
import Customers.Domain.{Customer, CustomerId, CustomerOrder, CustomerPage}
import Std.Collections

pub interface CustomerRepository {
  async func find(id: in CustomerId): Result[Customer, String]
  async func save(c: in Customer): Result[Customer, String]
  /// `count` customers from index `first` of the listing in `order`.
  async func page(first: in Int, count: in Int, order: in CustomerOrder, ascending: in Bool): Result[CustomerPage, String]
}
