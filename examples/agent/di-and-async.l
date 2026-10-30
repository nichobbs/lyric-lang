//! Dependency injection, async, and protected type examples.
package Examples.Di

import Std.Core
import Std.Collections

// ─── Domain types ────────────────────────────────────────────────────────────
pub record User {
  pub id: Long
  pub name: String
}

pub union AppError {
  case Conflict(message: String)
  case DbError(message: String)
}

// ─── Interfaces ──────────────────────────────────────────────────────────────
// `@stubbable` generates `ClockStub` (see tests.l). It is left off `UserRepo`
// because the generator skips `async` methods, which would leave its `impl`
// incomplete.
@stubbable
pub interface Clock {
  func now(): Long
}

pub interface UserRepo {
  async func findById(id: in Long): Option[User]
  async func save(user: in User): Result[Unit, String]
}

// ─── Implementations ─────────────────────────────────────────────────────────
pub record FixedClock {
  pub millis: Long
}

impl Clock for FixedClock {
  func now(): Long = self.millis
}

pub record InMemoryRepo {
  pub users: Map[Long, User]
}

impl UserRepo for InMemoryRepo {
  async func findById(id: in Long): Option[User] {
    return mapGet(self.users, id)
  }

  async func save(user: in User): Result[Unit, String] {
    self.users.add(user.id, user)
    return Ok(value = ())
  }
}

// ─── Service ─────────────────────────────────────────────────────────────────
pub record UserService {
  pub repo: UserRepo
  pub clock: Clock
}

pub async func createUser(svc: in UserService, id: in Long, name: in String): Result[User, AppError] {
  val existing = await svc.repo.findById(id)
  match existing {
    case Some(_) -> return Err(error = Conflict(message = "user already exists"))
    case None -> ()
  }
  val user = User(id = id, name = name)
  match await svc.repo.save(user) {
    case Ok(_) -> return Ok(value = user)
    case Err(e) -> return Err(error = DbError(message = e))
  }
}

// ─── Wire block ──────────────────────────────────────────────────────────────
pub record AppConfig {
  pub startMillis: Long
}

wire ProductionApp {
  @provided config: AppConfig
  singleton clock: Clock = FixedClock(millis = config.startMillis)
  singleton repo: UserRepo = InMemoryRepo(users = newMap())
  singleton service: UserService = UserService(repo = repo, clock = clock)
  expose service
}

// ─── Structured concurrency ──────────────────────────────────────────────────
async func loadProfile(userId: in Long): String {
  return "profile-${toString(userId)}"
}

async func loadActivity(userId: in Long): Int {
  return userId.toInt() * 10
}

// Sequential
async func loadSequential(userId: in Long): (String, Int) {
  val profile = await loadProfile(userId)
  val activity = await loadActivity(userId)
  return (profile, activity)
}

// Parallel with scope/spawn
async func loadParallel(userId: in Long): (String, Int) {
  scope {
    val profileTask = spawn loadProfile(userId)
    val activityTask = spawn loadActivity(userId)
    return (await profileTask, await activityTask)
  }
}

// ─── Protected type ──────────────────────────────────────────────────────────
protected type RateLimiter {
  var tokens: Int = 0
  invariant: tokens >= 0
  entry acquire(count: in Int): Unit
    requires: count > 0
    when: tokens >= count
  {
    tokens = tokens - count
  }
  entry refill(amount: in Int): Unit
    requires: amount > 0
  {
    tokens = tokens + amount
  }
  func available(): Int {
    tokens
  }
}

// ─── defer ───────────────────────────────────────────────────────────────────
func withLog(log: in List[String], work: in () -> Int): Int {
  log.add("start")
  defer {
    log.add("cleanup")   // runs on every exit: normal return, early return, panic
  }
  return work()
}

async func run(): Unit {
  val config = AppConfig(startMillis = 1000)
  ProductionApp.bootstrap(config)
  val svc = ProductionApp.service()
  println("clock: ${toString(svc.clock.now())}")
  println("create: ${describe(await createUser(svc, 1, "amy"))}")
  println("again: ${describe(await createUser(svc, 1, "amy"))}")

  val (profile, activity) = await loadSequential(4)
  println("sequential: ${profile} ${toString(activity)}")
  val (pProfile, pActivity) = await loadParallel(5)
  println("parallel: ${pProfile} ${toString(pActivity)}")

  val limiter = RateLimiter()
  limiter.refill(5)
  limiter.acquire(3)
  println("tokens left: ${toString(limiter.available())}")

  val log: List[String] = newList()
  val answer = withLog(log, { -> 42 })
  println("withLog: ${toString(answer)} ${log[0]},${log[1]}")
}

func main(): Unit {
  await run()
}

func describe(r: in Result[User, AppError]): String {
  return match r {
    case Ok(u) -> "created ${u.name}"
    case Err(Conflict(m)) -> "conflict: ${m}"
    case Err(DbError(m)) -> "db error: ${m}"
  }
}
