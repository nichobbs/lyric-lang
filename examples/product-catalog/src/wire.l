//! ProductCatalog.Wire — proto3 codecs and gRPC registration for the catalog.
//!
//! Field numbers match the `@proto_field` annotations in `domain.l` and
//! `proto/product_catalog.proto`. Code generation from those annotations is
//! planned (docs/37); until then the codecs are written by hand on `Proto`.
package ProductCatalog.Wire

import Std.Core
import Std.Collections
import Std.Encoding
import Proto
import Grpc
import Grpc.Types
import ProductCatalog.Domain
import ProductCatalog.Catalog

func decodeFields(bytes: in slice[Byte]): Result[List[DecodedField], GrpcStatus] {
  match decodeMessage(bytes) {
    case Err(e) -> return Err(Grpc.invalidArgument("malformed request: " + e))
    case Ok(fields) -> return Ok(fields)
  }
}

func varintOr(fields: in List[DecodedField], number: Int, fallback: Long): Long {
  match findVarint(fields, number) {
    case Some(v) -> return v
    case None -> return fallback
  }
}

func intOr(fields: in List[DecodedField], number: Int): Int {
  return longAsInt(varintOr(fields, number, 0i64))
}

func boolOr(fields: in List[DecodedField], number: Int): Bool {
  return varintOr(fields, number, 0i64) != 0i64
}

func stringOr(fields: in List[DecodedField], number: Int): String {
  match findBytes(fields, number) {
    case None -> return ""
    case Some(data) -> {
      match tryDecodeUtf8(data) {
        case Some(s) -> return s
        case None -> return ""
      }
    }
  }
}

func varField(number: Int, v: Int): ProtoField {
  return VarField(number, intAsLong(v))
}

func strField(number: Int, s: in String): ProtoField {
  return stringField(number, encodeUtf8(s))
}

func authToken(meta: in slice[GrpcMetadataEntry]): String {
  match Grpc.metadataGet(meta, "authorization") {
    case Some(v) -> return v
    case None -> return ""
  }
}

func encodeProduct(p: in Product): slice[Byte] {
  val fields: List[ProtoField] = newList()
  fields.add(VarField(1, p.id))
  fields.add(strField(2, p.name))
  fields.add(strField(3, p.description))
  fields.add(strField(4, p.category))
  fields.add(varField(5, p.priceCents))
  fields.add(boolField(6, p.inStock))
  fields.add(varField(7, p.stockCount))
  fields.add(strField(8, p.createdAt))
  return encodeMessage(fields)
}

func encodeListResponse(r: in ListProductsResponse): slice[Byte] {
  val fields: List[ProtoField] = newList()
  for p in r.products {
    fields.add(embeddedField(1, encodeProduct(p)))
  }
  fields.add(varField(2, r.total))
  return encodeMessage(fields)
}

func encodeDeleteResponse(r: in DeleteProductResponse): slice[Byte] {
  val fields: List[ProtoField] = newList()
  fields.add(boolField(1, r.deleted))
  return encodeMessage(fields)
}

pub func getProductHandler(bytes: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  match decodeFields(bytes) {
    case Err(s) -> return Err(s)
    case Ok(f) -> {
      match getProduct(GetProductRequest(id = varintOr(f, 1, 0i64)), authToken(meta)) {
        case Err(s) -> return Err(s)
        case Ok(p) -> return Ok(encodeProduct(p))
      }
    }
  }
}

pub func listProductsHandler(bytes: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  match decodeFields(bytes) {
    case Err(s) -> return Err(s)
    case Ok(f) -> {
      val req = ListProductsRequest(category = stringOr(f, 1), inStockOnly = boolOr(f, 2), pageSize = intOr(f, 3))
      match listProducts(req, authToken(meta)) {
        case Err(s) -> return Err(s)
        case Ok(r) -> return Ok(encodeListResponse(r))
      }
    }
  }
}

pub func createProductHandler(bytes: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  match decodeFields(bytes) {
    case Err(s) -> return Err(s)
    case Ok(f) -> {
      val req = CreateProductRequest(
        name = stringOr(f, 1),
        description = stringOr(f, 2),
        category = stringOr(f, 3),
        priceCents = intOr(f, 4),
        stockCount = intOr(f, 5),
        inStock = boolOr(f, 6)
      )
      match createProduct(req, authToken(meta)) {
        case Err(s) -> return Err(s)
        case Ok(p) -> return Ok(encodeProduct(p))
      }
    }
  }
}

pub func updateProductHandler(bytes: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  match decodeFields(bytes) {
    case Err(s) -> return Err(s)
    case Ok(f) -> {
      val req = UpdateProductRequest(
        id = varintOr(f, 1, 0i64),
        priceCents = intOr(f, 2),
        inStock = boolOr(f, 3),
        stockCount = intOr(f, 4)
      )
      match updateProduct(req, authToken(meta)) {
        case Err(s) -> return Err(s)
        case Ok(p) -> return Ok(encodeProduct(p))
      }
    }
  }
}

pub func deleteProductHandler(bytes: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  match decodeFields(bytes) {
    case Err(s) -> return Err(s)
    case Ok(f) -> {
      match deleteProduct(DeleteProductRequest(id = varintOr(f, 1, 0i64)), authToken(meta)) {
        case Err(s) -> return Err(s)
        case Ok(r) -> return Ok(encodeDeleteResponse(r))
      }
    }
  }
}

/// Register the five ProductService methods.
pub func registerProductService(registry: in ServiceRegistry): ServiceRegistry {
  val service = "ProductCatalog.ProductService"
  var r = Grpc.addUnary(registry, service, "GetProduct", getProductHandler)
  r = Grpc.addUnary(r, service, "ListProducts", listProductsHandler)
  r = Grpc.addUnary(r, service, "CreateProduct", createProductHandler)
  r = Grpc.addUnary(r, service, "UpdateProduct", updateProductHandler)
  r = Grpc.addUnary(r, service, "DeleteProduct", deleteProductHandler)
  return r
}
