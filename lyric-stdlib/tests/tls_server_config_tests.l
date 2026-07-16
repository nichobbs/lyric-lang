//! stdlib/tests/tls_server_config_tests.l — Tests for `Std.Tls.TlsServerConfig`
//! (docs/61-https-tls-http-versions.md §6.3, D128).
//!
//! `TlsServerConfig`'s omitted-defaults ergonomics (`TlsServerConfig(identity
//! = id)`, leaning on `minVersion`/`clientCa`/`requireClientCert`'s declared
//! defaults) do NOT have a test here — that construction shape currently
//! miscompiles on **both** targets under the source-built compiler: JVM gets
//! an incorrectly-populated field value for a cross-package record
//! constructed with an omitted default (#5908), and CI evidence against
//! `main`'s own toolchain (not just this sandbox's published fallback tool)
//! showed the identical construction throws
//! `System.InvalidProgramException: Common Language Runtime detected an
//! invalid program.` on `--target dotnet` too — the MSIL sibling of #5908,
//! filed as #5920. Per CLAUDE.md's "no skipped/known-failing tests" rule,
//! there is no test to gate on either target for this shape; restore it
//! once #5908 and #5920 both land. The remaining test below (every field
//! passed explicitly) is unaffected by either bug and runs on both targets.
@test_module
package Std.Tls.ServerConfigTests

import Std.Core
import Std.Tls
import Std.Testing

// Self-signed RSA 2048 certificate, CN=test-rsa, valid 2026-07-16..2036-07-13.
// Same fixture as tls_tests.l; duplicated rather than shared because
// lyric-stdlib/tests/*.l suites are self-contained source, no shared
// fixture modules.
val rsaCert = """
-----BEGIN CERTIFICATE-----
MIIDBzCCAe+gAwIBAgIUDO4hKdbmesejzWOGU8z7H2gwVQQwDQYJKoZIhvcNAQEL
BQAwEzERMA8GA1UEAwwIdGVzdC1yc2EwHhcNMjYwNzE2MjEzMTUzWhcNMzYwNzEz
MjEzMTUzWjATMREwDwYDVQQDDAh0ZXN0LXJzYTCCASIwDQYJKoZIhvcNAQEBBQAD
ggEPADCCAQoCggEBAMOdR2CrWmdulgLWwwPkz37aEMcm9vJENZ9J6sd9lxkltvSt
glE3EczI1m4f6IJiuUYq7//lwyaowapYCJvc2kbkUOFGDJfxe2ELkMgwops7gDGH
5lDh3CKMCVkGmtuk0FT+rIruwR+XgnDcw5ifPFEFE7vq96CVjyExh/JOyD2IOYOS
hR4oPER/6UAlTcURTZDm+LDxXA8BtiCAwj9XRaITNPsztd4X2rv7+EQUa2So06+b
OYBcCyMLO1wg6yRNVLSrDK9liy0yHoYfwfheswysgUsD2boK5wpw/tm817Sn0bk2
UtzdbHpU7Kbs5lVASsUXVbHw+NhgrpaHBs7Vb18CAwEAAaNTMFEwHQYDVR0OBBYE
FLlqJyx1wcyMlE4DrwcrLleQzmeBMB8GA1UdIwQYMBaAFLlqJyx1wcyMlE4Drwcr
LleQzmeBMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAC/yP0CP
My6At2yb5iCxuTQYE7rgZtv1wPR4/DkMEG06irJFIbOv2V00YmfX/xdnjv7980k+
BTGqdTqdZDP96kjNW/YSc103Y2BUug8DjZTaVil1Dxo3XmVLtjBzLZbvT2vhNjpz
ksKTsW6nzvDpaOxIEe+OkzRQ8/9US9BHIMNjySoLfIYipTSjoYEqt2xBzk6Nww2+
DJCeysBvs+6jNHnvWmbRP3TytQx8tL4i2cnQAbzGj3pIqWw6hyySt/nJq2bQX7AM
qxdPKRzWq4cCAx7gncwiyQsqO53BksnG8uQn/uJsT4lP0txrrwJRClypoKRV6+jq
mPcVDnIORvhyajE=
-----END CERTIFICATE-----
"""

// Matching unencrypted PKCS8 RSA private key.
val rsaKey = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDDnUdgq1pnbpYC
1sMD5M9+2hDHJvbyRDWfSerHfZcZJbb0rYJRNxHMyNZuH+iCYrlGKu//5cMmqMGq
WAib3NpG5FDhRgyX8XthC5DIMKKbO4Axh+ZQ4dwijAlZBprbpNBU/qyK7sEfl4Jw
3MOYnzxRBRO76veglY8hMYfyTsg9iDmDkoUeKDxEf+lAJU3FEU2Q5viw8VwPAbYg
gMI/V0WiEzT7M7XeF9q7+/hEFGtkqNOvmzmAXAsjCztcIOskTVS0qwyvZYstMh6G
H8H4XrMMrIFLA9m6CucKcP7ZvNe0p9G5NlLc3Wx6VOym7OZVQErFF1Wx8PjYYK6W
hwbO1W9fAgMBAAECggEAAIapPxwAc7vAbbe5yx/8sNrvdq5vYCpnQdgZV1vsdyCc
75G0AoI7opZfzgq9UvSzm09Utyd7DNSHrVMoAwlrTPqAh7XANnO4WoP0FGqIiBLM
hVnX52ikm+8KRNyVhMFaeJkbY5tSBW2PcIljtNx10zqd1TOy2iu6p2+yXIYUT5GC
sqTO7L1pimk1wD4RoLhGXSnK8oYXPCPyxWLfDNNw8HR8XhR0Xc9ZZtPap+qVOO6V
g2aVGHqHojwB9C52TS2a3xTW+H9gj6H8Iao8Zd3Wj7GDubslf6iLO/12SUF0/V42
dQ1KDg9eLOox02OP142UlVd7C5bBIYStaqoOha4k+QKBgQD8oCqkhdVoVFaqDcJ1
3aVIBrqaVYJ8RnjFr61ar2CNvh0GhA9iPYUCc86WWNSEkJ0Z9mfV4x9ROqI9Hf9F
ythB9H4zQTz9brdlOsFUJj4nCiaBV1l8u1QVlp1oWWhMawhhjcNCZmvlp4Kv6Lfr
8RfOw7C1YCyzVn3kxhU3QaWJaQKBgQDGOiqrvxply7lBvEJldDmwEgH8LzfU1+ia
Dnhq9LD+o3oxIUKSF8+Yi7EDiqR2qhqrju+OnrOIVCJptDTL+qPrvlGrkffzdh7f
kjUI6JcjFburuwFtyjZ3MgcwvmQqmoe5SbF39nukuWU7XNnamwjcecdK8xrRoMQi
wDbB19oRhwKBgBz40Wsk3iCk63t9MHwL+1STUPs6K0jNXDRvvVXVHyGiV/nTU2BU
5dguJ9ceQOEjJKFBnQ7uiTzrmIeh1RDP/pUx0PdX2ALIm8fEQT/BUwdvJpNWzTB8
21vOdibtegSpkcB+XZJT5LPlzhsWeWFZuP1BfBaQ/Q9kL/P4s54urSlhAoGAaOzt
HU/gpzV48ES4WH928a32gwhzYySOKM20C9lNvtvFmC/kzvPvnO2EWz2N5IoR5/GW
+EUk/uqZ9J3AvKAFGIn7LPfs6WAC45C+peKH7bhZSIOKNBUvU1SV3cVJvAtkAD3z
xG4h8IV6AjwZzM73l8yWIyQfdArHByX7VgvtkA0CgYEA11lPJlkOv3u/g1788zDb
EMHKJlE8t0ACUGfhHcxkvzCDJA0uiZUZNCVnkJPKaq+ITAaCnqa2eGqLqcyFOo5N
cTeg+l0KrzjQe6Q2hOojgqg7mskbY4sZGno7Pv+syl9h0aDjdxCBaX+ROQkm79IR
doONW2QlEIagNnVFFGh2abM=
-----END PRIVATE KEY-----
"""

test "TlsServerConfig accepts explicit non-default values" {
  match Identity.fromPem(rsaCert, rsaKey) {
    case Err(e) -> panic("expected Ok building the identity: " + TlsError.message(e))
    case Ok(identity) -> match Certificate.fromPem(rsaCert) {
      case Err(e) -> panic("expected Ok building the CA certificate: " + TlsError.message(e))
      case Ok(ca) -> {
        val cfg = TlsServerConfig(
          identity = identity,
          minVersion = Tls13,
          clientCa = Some(value = ca),
          requireClientCert = true
        )
        match cfg.minVersion {
          case Tls13 -> assertTrue(true, "minVersion honors an explicit Tls13")
          case Tls12 -> panic("expected explicit minVersion Tls13")
        }
        match cfg.clientCa {
          case Some(_) -> assertTrue(true, "clientCa honors an explicit certificate")
          case None -> panic("expected explicit clientCa Some")
        }
        assertTrue(cfg.requireClientCert, "requireClientCert honors an explicit true")
      }
    }
  }
}
