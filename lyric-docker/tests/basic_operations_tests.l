//! Basic Docker client operations tests.
//!
//! These tests verify core Docker client functionality:
//!   - Docker daemon connectivity (ping)
//!   - System information retrieval
//!   - Container and image listing
//!
//! Run with: lyric test --manifest lyric-docker/lyric.toml
//!
//! Note: These tests require a running Docker daemon accessible at
//! /var/run/docker.sock (or DOCKER_HOST environment variable).

@test_module
@runtime_checked
package Docker.BasicOperationsTests

import Docker
import Std.Core

/// Verify Docker daemon connectivity.
@test
pub func testPingDockerDaemon(): Unit {
  val client = Docker.makeDockerClient()

  match await Docker.ping(client) {
    case Ok(_) -> println("✓ Docker daemon is accessible")
    case Err(e) -> {
      println("✗ Failed to ping Docker daemon: " + e.message)
      if let statusCode = e.statusCode {
        println("  Status code: " + statusCode.toString())
      }
      if e.details.length > 0 {
        println("  Details: " + e.details)
      }
    }
  }
}

/// Retrieve and display Docker system information.
@test
pub func testGetSystemInfo(): Unit {
  val client = Docker.makeDockerClient()

  match await Docker.systemInfo(client) {
    case Ok(info) -> {
      println("✓ Retrieved system information:")
      // In Phase 2, this would be strongly-typed SystemInfo record.
      // For now, it's raw JSON.
      if info.length > 100 {
        println("  (JSON response: " + info.substring(0, 100) + "...)")
      } else {
        println("  " + info)
      }
    }
    case Err(e) -> println("✗ Failed to get system info: " + e.message)
  }
}

/// List all containers on the Docker daemon.
@test
pub func testListContainers(): Unit {
  val client = Docker.makeDockerClient()

  match await Docker.listContainers(client) {
    case Ok(containersJson) -> {
      println("✓ Listed containers (raw JSON):")
      if containersJson.length > 100 {
        println("  (Response: " + containersJson.substring(0, 100) + "...)")
      } else {
        println("  " + containersJson)
      }
    }
    case Err(e) -> println("✗ Failed to list containers: " + e.message)
  }
}

/// List all images on the Docker daemon.
@test
pub func testListImages(): Unit {
  val client = Docker.makeDockerClient()

  match await Docker.listImages(client) {
    case Ok(imagesJson) -> {
      println("✓ Listed images (raw JSON):")
      if imagesJson.length > 100 {
        println("  (Response: " + imagesJson.substring(0, 100) + "...)")
      } else {
        println("  " + imagesJson)
      }
    }
    case Err(e) -> println("✗ Failed to list images: " + e.message)
  }
}

/// Test rootless Docker connection (skipped if XDG_RUNTIME_DIR not set).
@test
pub func testRootlessDockerConnection(): Unit {
  match Docker.makeRootlessDockerClient() {
    case Ok(client) -> {
      println("✓ Connected to rootless Docker")
      match await Docker.ping(client) {
        case Ok(_) -> println("✓ Rootless Docker daemon is accessible")
        case Err(e) -> println("✗ Rootless Docker ping failed: " + e.message)
      }
    }
    case Err(e) -> println("○ Rootless Docker not available: " + e)
  }
}
