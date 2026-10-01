//! Customers.Store — an in-memory `CustomerRepository` for the demo.
//!
//! Layer: app (composition).  A real application binds a database-backed
//! repository here instead; nothing above the ports layer changes.
@runtime_checked
package Customers.Store

import Std.Core
import Std.Collections
import Std.String
import Std.Sort
import Customers.Domain.{Customer, CustomerId, CreditLimit, Tier, CustomerOrder, CustomerPage}
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

/// A repository seeded with three named customers and enough generated
/// ones (ids 4 to 200) to page through.
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
  var i = 4
  while i <= 200 {
    val n = padNumber(i)
    val tier = if i % 3 == 0 then Tier.Key else if i % 3 == 1 then Tier.Standard else Tier.Preferred
    t.put(
      Customer(
        id = CustomerId.from(i.toLong()),
        name = "Customer " + n,
        email = "customer" + n + "@example.test",
        creditLimit = CreditLimit.from(15000),
        tier = tier,
        notes = None
      )
    )
    i += 1
  }
  return MemoryRepository(table = t)
}

// `n` as three digits, so generated names sort in id order.
func padNumber(n: in Int): String {
  val s = n.toString()
  return if s.length >= 3 then s else if s.length == 2 then "0" + s else "00" + s
}

func tierRank(t: in Tier): Int {
  return match t { case Standard -> 0; case Preferred -> 1; case Key -> 2 }
}

// `a` before `b` in `order`, ties broken by id.
func compareIn(order: in CustomerOrder, ascending: in Bool, a: in Customer, b: in Customer): Int {
  val primary = match order {
    case ById -> 0
    case ByName -> compare(a.name, b.name)
    case ByEmail -> compare(a.email, b.email)
    case ByTier -> tierRank(a.tier) - tierRank(b.tier)
  }
  val directed = if ascending then primary else 0 - primary
  if directed != 0 {
    return directed
  }
  val ia = a.id.toLong()
  val ib = b.id.toLong()
  val byId = if ia < ib then -1 else if ia > ib then 1 else 0
  return match order { case ById -> if ascending then byId else 0 - byId; case _ -> byId }
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

  async func page(first: in Int, count: in Int, order: in CustomerOrder, ascending: in Bool): Result[CustomerPage, String] {
    val sorted = sort(self.table.values().toArray(), { a: Customer, b: Customer -> compareIn(order, ascending, a, b) })
    val acc: List[Customer] = newList()
    var i = if first > 0 then first else 0
    while i < sorted.length and i < first + count {
      acc.add(sorted[i])
      i += 1
    }
    return Ok(value = CustomerPage(total = sorted.length, customers = acc))
  }
}
