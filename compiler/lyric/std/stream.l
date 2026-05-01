// std/stream.l - lightweight stream interfaces.
//
// Phase 3 keeps streams deliberately small: callers choose buffer
// sizes explicitly, every operation is Result-returning, and close is
// visible so resource cleanup can be paired with defer.

@runtime_checked
package Std.Stream

import Std.Errors

pub interface ByteReader {
  // Return up to maxBytes. An empty successful slice means EOF.
  func read(maxBytes: in Nat): Result[slice[Byte], IOError]
    requires: maxBytes > 0
}

pub interface ByteWriter {
  // Write the complete slice or return an IOError.
  func write(bytes: in slice[Byte]): Result[Unit, IOError]

  // Force buffered bytes through the underlying resource.
  func flush(): Result[Unit, IOError]
}

pub interface TextReader {
  // Ok(None) means EOF. Err means the read itself failed.
  func readLine(): Result[Option[String], IOError]

  // Read remaining text up to maxChars so callers must choose a bound.
  func readToEnd(maxChars: in Nat): Result[String, IOError]
    requires: maxChars > 0
}

pub interface TextWriter {
  // Write text without adding a newline.
  func write(text: in String): Result[Unit, IOError]

  // Write text followed by the stream's newline convention.
  func writeLine(text: in String): Result[Unit, IOError]

  // Force buffered text through the underlying resource.
  func flush(): Result[Unit, IOError]
}

pub interface Closable {
  // Release the underlying resource. Designed to be paired with defer.
  func close(): Result[Unit, IOError]
}
