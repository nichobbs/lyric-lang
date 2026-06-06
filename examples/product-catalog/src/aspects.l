//! ProductCatalog.Aspects — aspect instantiation for the product catalog service.
//!
//! Binds the library templates from Grpc.Aspects to the catalog handlers:
//!
//!   GrpcAuth    — RequiresGrpcAuth on all handlers; reads authToken from gRPC metadata.
//!   GrpcCircuit — GrpcCircuitBreaker on all handlers, inside GrpcAuth.
//!
//! Ordering (outermost → innermost → handler):
//!   GrpcAuth → GrpcCircuit → handler
//!
//! Any handler that returns UNAUTHENTICATED bypasses the circuit counter
//! because the request never reaches the handler body.

@runtime_checked
package ProductCatalog.Aspects

import Grpc.Aspects

aspect GrpcAuth from Grpc.Aspects.RequiresGrpcAuth {
  matches: name in {
    ProductCatalog.Catalog.getProduct,
    ProductCatalog.Catalog.listProducts,
    ProductCatalog.Catalog.createProduct,
    ProductCatalog.Catalog.updateProduct,
    ProductCatalog.Catalog.deleteProduct
  }
}

aspect GrpcCircuit from Grpc.Aspects.GrpcCircuitBreaker {
  matches: name in {
    ProductCatalog.Catalog.getProduct,
    ProductCatalog.Catalog.listProducts,
    ProductCatalog.Catalog.createProduct,
    ProductCatalog.Catalog.updateProduct,
    ProductCatalog.Catalog.deleteProduct
  }
  inside: GrpcAuth
  config {
    failureThreshold: Int = 3
    cooldownMs:       Int = 15000
  }
}
