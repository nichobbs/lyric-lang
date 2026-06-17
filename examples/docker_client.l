//! Docker client example — Connect to Docker daemon and list containers/images.
//!
//! This example demonstrates:
//!   - Connecting to the Docker daemon via Unix socket
//!   - Error handling with Result types
//!   - Async operations with await
//!   - JSON response handling
//!
//! Run with:
//!   lyric run examples/docker_client.l
//!
//! Prerequisites:
//!   - Docker daemon running and accessible at /var/run/docker.sock
//!   - User has permission to access the socket (docker group or sudo)

@runtime_checked
package Docker.Examples

import Docker
import Std.Core

pub func main(): Int {
  val exitCode = await dockerClientDemo()
  exitCode
}

async func dockerClientDemo(): Int {
  println("Docker Client Example")
  println("=====================\n")

  // Step 1: Connect to Docker daemon
  println("[1/4] Connecting to Docker daemon...")
  val client = Docker.makeDockerClient()
  println("✓ Docker client created (will connect on first request)\n")

  // Step 2: Verify connectivity with ping
  println("[2/4] Verifying connectivity...")
  match await Docker.ping(client) {
    case Ok(_) -> {
      println("✓ Docker daemon is accessible\n")
    }
    case Err(e) -> {
      println("✗ Failed to connect to Docker daemon")
      println("  Error: " + e.message)
      if e.statusCode.isSome() {
        val code = e.statusCode.assertSome()
        println("  Status: " + code.toString())
      }
      if e.details.length > 0 {
        println("  Details: " + e.details)
      }
      return 1
    }
  }

  // Step 3: Get system information
  println("[3/4] Retrieving Docker system information...")
  match await Docker.systemInfo(client) {
    case Ok(info) -> {
      println("✓ System information retrieved:")
      // Pretty-print first 200 chars of JSON response
      val displayInfo = if info.length > 200 {
        info.substring(0, 200) + "..."
      } else {
        info
      }
      println("  " + displayInfo)
      println("")
    }
    case Err(e) -> {
      println("✗ Failed to get system information: " + e.message)
      return 1
    }
  }

  // Step 4: List containers and images
  println("[4/4] Listing containers and images...")

  // List containers
  match await Docker.listContainers(client) {
    case Ok(containersJson) -> {
      val containerCount = countJsonArrayElements(containersJson)
      println("✓ Found " + containerCount.toString() + " container(s)")
      if containerCount > 0 && containersJson.length > 50 {
        println("  (Sample: " + containersJson.substring(0, 50) + "...)")
      }
    }
    case Err(e) -> println("✗ Failed to list containers: " + e.message)
  }

  // List images
  match await Docker.listImages(client) {
    case Ok(imagesJson) -> {
      val imageCount = countJsonArrayElements(imagesJson)
      println("✓ Found " + imageCount.toString() + " image(s)")
      if imageCount > 0 && imagesJson.length > 50 {
        println("  (Sample: " + imagesJson.substring(0, 50) + "...)")
      }
    }
    case Err(e) -> println("✗ Failed to list images: " + e.message)
  }

  println("")
  println("Example completed successfully!")
  0
}

/// Simple helper to estimate JSON array element count.
/// Counts commas between '[' and ']' as a rough heuristic.
/// For production use, would parse the JSON properly.
func countJsonArrayElements(jsonArray: in String): Int {
  if jsonArray.length < 2 {
    return 0
  }

  val startIdx = jsonArray.indexOf('[')
  val endIdx = jsonArray.lastIndexOf(']')

  if startIdx < 0 || endIdx < 0 || startIdx >= endIdx {
    return 0
  }

  val slice = jsonArray.substring(startIdx + 1, endIdx)

  if slice.length == 0 {
    return 0
  }

  // Count top-level commas (rough approximation)
  var count = 1
  var i = 0
  var braceDepth = 0

  while i < slice.length {
    val ch = slice.charAt(i)
    if ch == '{' {
      braceDepth += 1
    } else if ch == '}' {
      braceDepth -= 1
    } else if ch == ',' && braceDepth == 1 {
      count += 1
    }
    i += 1
  }

  count
}
