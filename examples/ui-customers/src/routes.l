//! Customers.Routes — the application's pages as a typed union
//! (docs/65-ui-library-sketch.md §6.1).
//!
//! Layer: logic, so logic and views can name pages without writing URLs.
//! `@generate(Ui.Routes)` derives `parseRoute(url)` and `routeUrl(r)` (D151).
@runtime_checked
package Customers.Routes

import Std.Core
import Customers.Domain.{CustomerId}

@generate(Ui.Routes)
pub union Route {
  @path("/customers")
  case CustomerList
  @path("/customers/{id:Long}")
  case EditCustomer(id: CustomerId)
}
