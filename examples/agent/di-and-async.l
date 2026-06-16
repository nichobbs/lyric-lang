//! Dependency injection, async, and protected type examples.
package Examples.Di
import Std.Core
import Std.Time.{Instant, Clock}

// ─── Interfaces ──────────────────────────────────────────────────────────────

pub interface Clock {
  func now(): Instant
}

@stubbable
pub interface UserRepo {
  async func findById(id: in UserId): Option[User]
  async func save(user: in User): Result[Unit, DbError]
}

@stubbable
pub interface EmailSender {
  async func send(to: in String, subject: in String, body: in String): Result[Unit, SendError]
}

// ─── Implementation ──────────────────────────────────────────────────────────

impl Clock for SystemClock {
  func now(): Instant = Instant.now()
}

// ─── Service ─────────────────────────────────────────────────────────────────

pub record UserService {
  repo:   UserRepo
  mailer: EmailSender
  clock:  Clock
}

pub async func (svc: in UserService) createUser(req: in CreateUserRequest): Result[User, AppError] {
  val existing = await svc.repo.findById(req.id)
  match existing {
    case Some(_) -> return Err(AppError.Conflict("user already exists"))
    case None    -> ()
  }

  val user = User(id = req.id, name = req.name, createdAt = svc.clock.now())

  await svc.repo.save(user).mapErr { e -> AppError.DbError(e.message()) }?
  await svc.mailer.send(
    to      = req.email,
    subject = "Welcome!",
    body    = "Hello, ${req.name}"
  ).mapErr { e -> AppError.EmailError(e.message()) }?

  return Ok(user)
}

// ─── Wire block ──────────────────────────────────────────────────────────────

wire ProductionApp {
  @provided config: AppConfig
  @provided cancellationToken: CancellationToken

  singleton clock:   Clock       = SystemClock.make()
  singleton repo:    UserRepo    = PostgresUserRepo.make(config.dbUrl)
  singleton mailer:  EmailSender = SmtpSender.make(config.smtpHost)
  singleton service: UserService = UserService(repo = repo, mailer = mailer, clock = clock)

  expose service
}

// ─── Entry point ─────────────────────────────────────────────────────────────

func main(): Unit {
  val config = unwrapResult(AppConfig.load(RawConfig.readFromEnvironment()))
  val app = ProductionApp.bootstrap(config, CancellationToken.none())
  // app.service is the resolved UserService
}

// ─── Structured concurrency ──────────────────────────────────────────────────

// Sequential
async func loadSequential(userId: in UserId): (Profile, slice[Activity]) {
  val profile  = await loadProfile(userId)
  val activity = await loadActivity(userId)
  return (profile, activity)
}

// Parallel with scope/spawn
async func loadParallel(userId: in UserId): (Profile, slice[Activity]) {
  scope {
    val profileTask  = spawn loadProfile(userId)
    val activityTask = spawn loadActivity(userId)
    return (await profileTask, await activityTask)
  }
}

// ─── Protected type ──────────────────────────────────────────────────────────

protected type RateLimiter {
  var tokens: Double
  invariant: tokens >= 0.0

  entry acquire(count: in Double): Unit
    requires: count > 0.0
    when: tokens >= count
  {
    tokens = tokens - count
  }

  entry refill(amount: in Double): Unit
    requires: amount > 0.0
  {
    tokens = tokens + amount
  }
}

// ─── defer ───────────────────────────────────────────────────────────────────

async func withSemaphore(sem: in Semaphore, work: in {-> async Result[Unit, AppError]}): Result[Unit, AppError] {
  await sem.acquire()
  defer { sem.release() }   // runs on all exits: normal return, early return, bug
  return await work()
}

// ─── Cancellation ────────────────────────────────────────────────────────────

async func processAll(items: in slice[Item]): Result[Unit, AppError] {
  for item in items {
    cancellation.checkOrThrow()   // cooperative cancellation point
    await processOne(item)?
  }
  return Ok(())
}
