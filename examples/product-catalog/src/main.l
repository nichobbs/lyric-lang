//! ProductCatalog.Main — gRPC server entry point.
//!
//! Registers all five ProductService methods and starts the Kestrel-backed
//! gRPC server.  The server address and port are controlled by env vars:
//!   LYRIC_CONFIG_GRPC_SERVER_HOST — default 0.0.0.0
//!   LYRIC_CONFIG_GRPC_SERVER_PORT — default 50051
//!   LYRIC_CONFIG_GRPC_SERVER_REFLECTIONENABLED — default false
//!
//! Auth configuration:
//!   LYRIC_ASPECT_GRPCAUTH_JWTSECRET  — required; HMAC-SHA256 signing secret
//!   LYRIC_ASPECT_GRPCAUTH_ISSUER     — optional; expected iss claim
//!   LYRIC_ASPECT_GRPCAUTH_AUDIENCE   — optional; expected aud claim
//!
//! Database configuration:
//!   LYRIC_CONFIG_CATALOGDB_CONNECTIONSTRING — required; PostgreSQL DSN
@runtime_checked
package ProductCatalog.Main

import Std.Core
import Grpc
import ProductCatalog.Aspects

pub func main(): Int {
  val service = "ProductCatalog.ProductService"

  val registry = Grpc.create()
  val registry = Grpc.addMethod(registry, service, "GetProduct", "ProductCatalog.Catalog.getProduct")
  val registry = Grpc.addMethod(registry, service, "ListProducts", "ProductCatalog.Catalog.listProducts")
  val registry = Grpc.addMethod(registry, service, "CreateProduct", "ProductCatalog.Catalog.createProduct")
  val registry = Grpc.addMethod(registry, service, "UpdateProduct", "ProductCatalog.Catalog.updateProduct")
  val registry = Grpc.addMethod(registry, service, "DeleteProduct", "ProductCatalog.Catalog.deleteProduct")

  Grpc.start(registry)
  return 0
}
