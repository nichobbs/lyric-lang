//! Customers.Store — an in-memory `CustomerRepository` for the demo.
//!
//! Layer: app (composition).  A real application binds a database-backed
//! repository here instead; nothing above the ports layer changes.
@runtime_checked
package Customers.Store

import Std.Core
import Std.Collections
import Customers.Domain.{Customer, CustomerId, CreditLimit, Tier}
import Customers.Ports.{CustomerRepository}

protected type Table {
  var rows: Map[Long, Customer] = newMap()
  entry put(c: in Customer): Unit {
    val k = c.id.toLong()
    if rows.containsKey(k) {
      rows.remove(k)
    }
    rows.add(k, c)
  }
  func get(id: in Long): Option[Customer] {
    return mapGet(rows, id)
  }
  func values(): List[Customer] {
    return mapValues(rows)
  }
}

pub record MemoryRepository {
  table: Table
}

/// A repository seeded with a few customers.
pub func seeded(): MemoryRepository {
  val t = Table()
  t.put(
    Customer(
      id = CustomerId.from(1),
      name = "Acme Pty Ltd",
      email = "accounts@acme.test",
      creditLimit = CreditLimit.from(25000),
      tier = Tier.Key,
      notes = None
    )
  )
  t.put(
    Customer(
      id = CustomerId.from(2),
      name = "Birchwood Joinery",
      email = "office@birchwood.test",
      creditLimit = CreditLimit.from(5000),
      tier = Tier.Standard,
      notes = Some(value = "Pays on 30-day terms")
    )
  )
  t.put(
    Customer(
      id = CustomerId.from(3),
      name = "Coastal Freight",
      email = "billing@coastal.test",
      creditLimit = CreditLimit.from(12000),
      tier = Tier.Preferred,
      notes = None
    )
  )
  return MemoryRepository(table = t)
}

impl CustomerRepository for MemoryRepository {
  async func find(id: in CustomerId): Result[Customer, String] {
    return match self.table.get(id.toLong()) {
      case Some(c) -> Ok(value = c)
      case None -> Err(error = "no customer with id " + id.toString())
    }
  }

  async func save(c: in Customer): Result[Customer, String] {
    self.table.put(c)
    return Ok(value = c)
  }

  async func all(): Result[List[Customer], String] {
    return Ok(value = self.table.values())
  }
}
