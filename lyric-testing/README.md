# lyric-testing

Mock implementations and assertion helpers for unit testing Lyric applications
without real infrastructure.

## Packages

| Package | Purpose |
|---|---|
| `Testing` | Core mock types, `TestContext` factory, and assertion helpers |

## Quick start

```lyric
import Testing
import Mail
import Storage

val testCtx = Testing.newTestContext()

// All mocks are pre-wired in testCtx
match Mail.sendSimple(testCtx.mailSender, "noreply@example.com", "user@example.com", "Test", "Body") {
  case Ok(_) ->
    val count = Testing.sentCount(testCtx.mailSender)
    Testing.assertTrue(count == 1)
  case Err(_) ->
    Testing.assertFalse(true)
}
```

## Mock types

The `TestContext` includes pre-wired mock implementations:

```lyric
pub record TestContext {
  mailSender: Mail.MailSender
  storageBucket: Storage.StorageBucket
  messageQueue: Mq.MessageQueue
  sessionStore: Session.SessionStore
  flagStore: Flags.FlagStore
  testClock: Time.Clock
}
```

### Creating a test context

```lyric
val testCtx = Testing.newTestContext()

// Use the mocks in your test code
val result = myService.process(testCtx.flagStore)
```

All mocks start empty and isolated. No state leaks between tests.

## Assertion helpers

```lyric
Testing.assertOk(result: Result[T, E])          // Fails if result is Err
Testing.assertErr(result: Result[T, E])         // Fails if result is Ok
Testing.assertSome(value: Option[T])            // Fails if value is None
Testing.assertNone(value: Option[T])            // Fails if value is Some
Testing.assertEq(actual: T, expected: T)        // Fails if not equal
Testing.assertTrue(cond: Bool)                  // Fails if false
Testing.assertFalse(cond: Bool)                 // Fails if true
```

## Mail mock helpers

```lyric
Testing.lastSent(mailSender: in MockMailSender)
  -> Option[Mail.EmailMessage]

Testing.sentCount(mailSender: in MockMailSender)
  -> Int

Testing.clearSent(mailSender: inout MockMailSender)
  -> Unit
```

Example:

```lyric
Mail.sendSimple(testCtx.mailSender, "from@test.com", "to@test.com", "Subject", "Body")?

val last = Testing.lastSent(testCtx.mailSender)
match last {
  case Some(msg) ->
    Testing.assertEq(msg.subject, "Subject")
  case None ->
    Testing.assertFalse(true)
}

Testing.clearSent(testCtx.mailSender)
Testing.assertEq(Testing.sentCount(testCtx.mailSender), 0)
```

## Flag mock helpers

Enable or disable feature flags at runtime:

```lyric
Testing.enable(flagStore: inout MockFlagStore, key: in String)
  -> Unit

Testing.disable(flagStore: inout MockFlagStore, key: in String)
  -> Unit
```

Note: these take `inout` parameter mode because they mutate the mock.

Example:

```lyric
val testCtx = Testing.newTestContext()

Testing.disable(testCtx.flagStore, "newFeature")
Testing.assertFalse(Flags.isEnabled(testCtx.flagStore, "newFeature"))

Testing.enable(testCtx.flagStore, "newFeature")
Testing.assertTrue(Flags.isEnabled(testCtx.flagStore, "newFeature"))
```

## Clock mock helpers

Advance the test clock for time-dependent code:

```lyric
Testing.advance(clock: inout TestClock, duration: in Duration)
  -> Unit

Testing.now(clock: in TestClock)
  -> Instant
```

Example:

```lyric
val testCtx = Testing.newTestContext()
val before = Testing.now(testCtx.testClock)

Testing.advance(testCtx.testClock, Duration.seconds(10))

val after = Testing.now(testCtx.testClock)
Testing.assertTrue(after > before)
```

## Storage mock helpers

```lyric
Testing.putString(bucket: inout MockStorageBucket, key: in String, value: in String)
  -> Result[Unit, StorageError]

Testing.getString(bucket: inout MockStorageBucket, key: in String)
  -> Result[Option[String], StorageError]

Testing.deleteKey(bucket: inout MockStorageBucket, key: in String)
  -> Result[Unit, StorageError]
```

## Message queue mock helpers

```lyric
Testing.queuedCount(queue: in MockMessageQueue)
  -> Int

Testing.peekMessage(queue: in MockMessageQueue)
  -> Option[Mq.Message]

Testing.clearQueue(queue: inout MockMessageQueue)
  -> Unit
```

## Decision log

See `docs/03-decision-log.md` D-progress-XXX.
