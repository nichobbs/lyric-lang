//! stdlib/tests/tcp_host_tls_tests.l — runtime tests for the dotnet TCP +
//! server-side TLS transport kernel `Std.TcpHost`
//! (docs/61-https-tls-http-versions.md §6.1/§6.3, phase 3.1 of epic #5874,
//! issue #5882).
//!
//! Runs on `--target dotnet` and `--target jvm`: `Std.TcpHost` is
//! `System.Net.Sockets` + `SslStream` on dotnet and `java.net.Socket` +
//! `SSLSocket` on the JVM (`_kernel_jvm/tcp_host.l`, #9042). Native has its own
//! twin and test (`tcp_host_bounded_native_tests.l`).
//!
//! Coverage: `TcpError.message`, a `hostListen` bind-failure, a plain
//! loopback echo round trip (accept/connect/read/write/close + `hostAlpn ==
//! ""` for a plain connection), a full server-side TLS handshake + HTTP/1.1
//! request/response byte round trip against the REAL Lyric HTTPS client
//! (`HttpClientBuilder.withExclusiveCaCertificate`, #5877), and both mTLS
//! outcomes (a client cert that chains to `clientCa` is accepted; a client
//! that presents no cert with `requireClientCert` is rejected at the
//! handshake). The transport advertises `h2` + `http/1.1` (phase 4.4), but
//! `serveOneTls` is a raw HTTP/1.1 echo server, so the round-trip tests pin the
//! client to HTTP/1.1 (`withHttpVersion(Http11)`) — a .NET HttpClient pinned to
//! 1.1 sends no ALPN, so the server reports `hostAlpn == ""` (the JDK client
//! offers `http/1.1`, which the JVM server reports); the h2 ALPN end-to-end path is
//! covered by `http_server_tests.l`. The server echoes
//! its own `hostAlpn` in the response body, so
//! a main-thread assertion confirms the negotiated protocol end to end.
//!
//! Concurrency: an in-process loopback needs the server accept loop and the
//! client to run on separate threads (Lyric `spawn` is degenerate-synchronous on
//! `--target dotnet`, D119/D120), so the server side runs under
//! `Std.Task.scopeSpawn`, a pool task on dotnet and a virtual thread on the JVM.
//!
//! Client TLS (docs/72 slice 4): `hostConnectTls` / `hostUpgradeClientTls`
//! and `hostReadDeadline` are exercised against the kernel's own server side
//! (`hostAcceptTls`) with a pinned CA: a successful handshake, a hostname
//! mismatch (a chain that verifies for another name), an expired and an
//! untrusted certificate, ALPN `h2` / `http/1.1` / none, an mTLS client
//! identity, the minimum version, a malformed trust PEM, and the insecure
//! trust decision. They run on both targets; hostname verification matters
//! most on the JVM, where a raw `SSLSocket` does not verify the name unless
//! the endpoint identification algorithm is set.
//!
//! Fixtures: a self-signed CA, a server leaf with `SAN=DNS:localhost,IP:
//! 127.0.0.1` signed by it (so the .NET client's hostname check passes when
//! connecting to `https://localhost`), and a client leaf signed by the same
//! CA for the mTLS-accept case. A second CA (`caBPem`) signs a leaf for another
//! name (`other.example`) and an expired `localhost` leaf, for the client's
//! negative cases. All are embedded PEM (self-contained, as in
//! `tls_tests.l`), valid 2026-07-18..2036-07-15 except the expired leaf
//! (2020-01-01..2020-01-02).
@test_module
package Std.TcpHost.TlsTests

import Std.Core
import Std.Encoding
import Std.String
import Std.Tls
import Std.TcpHost
import Std.Http
import Std.Testing
import Std.Collections
import Std.Errors
import Std.Task as Task
import Std.Time as Time

val caCertPem = """
-----BEGIN CERTIFICATE-----
MIIDETCCAfmgAwIBAgIUHAnWv6jzrCpsNoAYgRNWauQnnr0wDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNbHlyaWMtdGVzdC1jYTAeFw0yNjA3MTgwNzQyMzJaFw0z
NjA3MTUwNzQyMzJaMBgxFjAUBgNVBAMMDWx5cmljLXRlc3QtY2EwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDd9+G8LLfeYkUd2KAdm0BfTrzVJquwm+/K
XIlei1KvQpjK/CIypyBWaQD5Hy/jMORnK1olPSP0kGGCAZo9+usfQmG/f9oHrZK3
a4tsBwo2NSJ3SGrSweCnHQiBC/F5P7b1SOTqFfC9NR5lQk8zHQnWagxkc7C/lXKU
1UeJavjdEgt4c6zbuXdCYCRsgnFfloIw4ilY9oyzg4oCcT1mLKYW2jPcnZs+Xloc
xyfXnWK60WHrDdlL5rAfGWT6Knu0mzpgXUnCFVkN60uDPRc1EJnpy6xEi6qUYns/
FRE8FHzXoSRKQkfN1z5CMaY+PmQfnvlBbWBJZVVBMKFZdCjo5SFDAgMBAAGjUzBR
MB0GA1UdDgQWBBQIcW5jDzQRQrZlYT7RorEGAkccFzAfBgNVHSMEGDAWgBQIcW5j
DzQRQrZlYT7RorEGAkccFzAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUA
A4IBAQBopXJDnAHpdqv1Psx8vAJ6v8RGJS3zuT63j+j/WFUeGQf7UbGW29za+sxr
yu+4RzKSnf29JCuQSEJ5DGjmh2AwPYSGvR6fO8f+h8++w/Ltw/E1wixE17NsFMLX
wXWMXhO2N49ehfGgJWbUMEL91qx/WOxtf8Z2Ljf3bi+xDFSEuiYba0a8VHSLq2WC
VCgisgaVP7oAYKjK1XaMip+a4ThI9HXZ6DsHJmmxEDBpGmikkBNhPbsVo9uuiNR/
c95c0HA4TUKMHXHLPjZrNCbLjM+fllPEH8thxvSHaYAbSYjGi4gg6drmpdjvcJ5F
H9nUvY6o5f2w41gyG0qTNx0tu4ld
-----END CERTIFICATE-----
"""

val serverCertPem = """
-----BEGIN CERTIFICATE-----
MIIDGDCCAgCgAwIBAgIULWRn9gh8NN75EVpn5QgfES55PcMwDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNbHlyaWMtdGVzdC1jYTAeFw0yNjA3MTgwNzQyMzJaFw0z
NjA3MTUwNzQyMzJaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBAK3jysZKZuOw3iRVHNxhaoKpURK3mq0rNrBiAzGx
5NPDh7UQlSNjIQqWkADKCLe7Yz5EKdPc1GmwY3Lfs9Y9qdxrw9gvFlYWRfXPq4lV
SFPX/OYufRvTlVkDfOuO5SBzZmhFxVJL/ygWeXe9nZRShBQMkpac1daUhsLR57sv
LERej9pT8prMQlGhOBA065OsisOHbiXDA8wCYO6C2ZTZ+WLN/ZdKTfyNoL0lRs/H
mHKNvzjZbRYdjPUyBfqmtFhBgc2mJDSQMrwmntLSh9J2Pe7Nk4fI8snCwucQSgm1
kwMgZYP/rPDaVFn2vagDhCwFIKgE8arb1Zuw77YQAf95EVcCAwEAAaNeMFwwGgYD
VR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMB0GA1UdDgQWBBS394tqWuNElfTcMY6e
ZYEVzqSEmDAfBgNVHSMEGDAWgBQIcW5jDzQRQrZlYT7RorEGAkccFzANBgkqhkiG
9w0BAQsFAAOCAQEAsbKLjP/NLU6nTjZMINgWDh3jmYLYPi1WTza0iQ1/naSDDjRj
StXxbwXLuWAKDAsQEgMqDba86QccWmUrtDMAzVwqr+m20x2fHtI4WWAWbLZdqEje
vgVVRph8ohAXIGbqKzyGBfgoxWmATxJCAM4+MCgU8wHuiz1vndzmEXZ0PQR/aRHm
1YZtwUDbV4T8BKS3RlFn8uk1v5enxUjp+TsrKbdfAfvpRNOhKsIPVhCjOM6RC+QN
li0ylHyST0tfJ7rMv8x4VbqofOQT4QpJuvXWQZHs06VOHU2YvViGfG/bhm/76Ku9
KGnPfvo09kP0A5oO14Q52uRQV5mYBkX5TsZLnw==
-----END CERTIFICATE-----
"""

val serverKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCt48rGSmbjsN4k
VRzcYWqCqVESt5qtKzawYgMxseTTw4e1EJUjYyEKlpAAygi3u2M+RCnT3NRpsGNy
37PWPanca8PYLxZWFkX1z6uJVUhT1/zmLn0b05VZA3zrjuUgc2ZoRcVSS/8oFnl3
vZ2UUoQUDJKWnNXWlIbC0ee7LyxEXo/aU/KazEJRoTgQNOuTrIrDh24lwwPMAmDu
gtmU2flizf2XSk38jaC9JUbPx5hyjb842W0WHYz1MgX6prRYQYHNpiQ0kDK8Jp7S
0ofSdj3uzZOHyPLJwsLnEEoJtZMDIGWD/6zw2lRZ9r2oA4QsBSCoBPGq29WbsO+2
EAH/eRFXAgMBAAECggEACKrCaBi8QRwHLnNpkVhvqRyMVGz/UiNFwgvYkekGeUGV
KYKulEl0E6WGfuuS/Klj3G4kUZF/qtbmVgrtWT/QkBJ0+/j42YiZqxNTPvCXvsoU
qlpl1PW6S2n/l3QTWoc18vuLRrtP9+0K19uFF6f3OlKYGdauV9gmUV6J+Mv0nmGt
AEKLVROAg2xdML8WlW0HXmPZtg0ACrR2aE4udV4sq2ulCPEeaAHYCZ7w7p4mzKuh
tdm6BE1nQXtUVLiHDrwB1Hi51bsocwC7tEF3fLgHrx6TEWF6d3937JPzUZLtS8pe
qvJDLNc/aMeydY2EBIH3F14wWQ32B69FwM1YzKNYcQKBgQDv1vM+EIrx4MAaz2e3
qy5PWL8F6m+L7HArwSx7rWc2QJ73yLVlCxvavKK+ToCQljeT1ou5nlRonszUhecE
zX3DXnPV0o+7p9Y7OwG2sjkJmgPjdRFnWuOjcnJrPnEw4kTlzd7A9Cvu9sKsI9Gu
nqtPNKI443th6o8Ug+lfTzLOZwKBgQC5m0ID/8kz/3xR3u7gZwPK//INuHfxXzza
Ps6lagEo+Dr6UZtFGRSqLtQ7L+HcGq+306wwJ4oqf6av537ZzYgtNsPHUCxCtvWe
aV4F5P0uwU/YR/d366TSGXECw7lm5Fd8URMAWwHXiH/zy0eJm8XEViucHXGHvlpx
+f1xgwDvkQKBgCaerTJsRYNnVme6yA+6P83FE5VnR6j3XKSfCYOsy3bf9vkdV6A6
prSVNXuBdpBRsAddP8iW5y6li4QZP7b1Q/AGsI5Yxo5IG2YUPVVm42pZY5Dn0/KZ
nxg9oJEGUAG4HbIHcXwOlVh4YaaIagY9RIaPiiOw9bgxpfJ+v0B6p0q3AoGAM2Hu
6aqDKfj9krCz0r3SB/3JJdE+qzyhXQ3sKVDqV0w5D5lN8dgap25lZKlBzqw4nxxj
W8Vmc5N5MtNUg7lpjJLPqjrgtetundcvp1QYXzw2/XoW4UUEEQHoDkre5cQrEAhl
yUBohyGLwpMxD8BnBI6Sbhqclma1JT5+0lDhDnECgYAwzWxRe9KUwT/MuktbYvBr
hc/u/FLNekzSpyBpofYdPxZFA++6tMnfDHzUYj+c8vTimarL/3eg32tlxVjx2awZ
yRV4a3HFSdOFVQOKw57bMaQA8+M8GZ8RsAusrzDS28gubyjOJBpzz8Rg5RFmUZ1M
Ctkm17tiE4Fcz1p3gfUr4A==
-----END PRIVATE KEY-----
"""

val clientCertPem = """
-----BEGIN CERTIFICATE-----
MIICuzCCAaMCFC1kZ/YIfDTe+RFaZ+UIHxEueT3EMA0GCSqGSIb3DQEBCwUAMBgx
FjAUBgNVBAMMDWx5cmljLXRlc3QtY2EwHhcNMjYwNzE4MDc0MjMyWhcNMzYwNzE1
MDc0MjMyWjAcMRowGAYDVQQDDBFseXJpYy10ZXN0LWNsaWVudDCCASIwDQYJKoZI
hvcNAQEBBQADggEPADCCAQoCggEBANGf5N8qES33noFWxMoIUj/lMLR2Cvj8DBge
gog1e0VlPXVMcAtFl4+6rkbhEADG7EBMH+sSCXA0uLAoS/ZjZ7lwL+boRf8R84sH
sUiCeLcvz7Grqzusgu2z8xqfXPVnU5s0W1l6mOe6djBouWQPOb2jv+ENH6cz7Udn
9mTbGTw8tm30P2RJBSNd++ahcLeiEHH9yT2WIznlMbdjMeM1txkcp9rx9wOCkgYv
sDtqW0R8vJBU7eYvOg3rQhJYG+36pG4aSGN0hk5ToXr1KXUqBfG5bihkIXtRmyUz
RkdbAcHcNgpw6MWReqkKo5S3fyNbPkBfsdTiy8UX3bcAHObVC1cCAwEAATANBgkq
hkiG9w0BAQsFAAOCAQEAX/DpZQz7RRocRV2pdmlYTv1C94DMVMjFx7yhqwVUwq1o
C6wRQbF0hftejS96lp+yvGho8xqSiXNoMpvYrKJ6irs04CdvbPA5EKfBpGkX67C9
XMnnoy33NNHuHXWgFdaNcQu0RexClCNdrt7GhZhSdHMaFqShapxM6IRga7mAaLoH
aoSVJHUqcvSp6emabapa1mBQGDmQvChIlId8goTyT7jiMLEGHIkx6UU5lOGpoaNw
sKS14qcf1mfWrCj7x55Q+FZyBhZMNhYwTk3TgmcHyNF9iuuUYWrzYwMa6HIUCFOM
obXTzZgP3SUsl/eCQ4VUOxHGhgJk3QeWkU3Q/EpqbA==
-----END CERTIFICATE-----
"""

val clientKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDRn+TfKhEt956B
VsTKCFI/5TC0dgr4/AwYHoKINXtFZT11THALRZePuq5G4RAAxuxATB/rEglwNLiw
KEv2Y2e5cC/m6EX/EfOLB7FIgni3L8+xq6s7rILts/Man1z1Z1ObNFtZepjnunYw
aLlkDzm9o7/hDR+nM+1HZ/Zk2xk8PLZt9D9kSQUjXfvmoXC3ohBx/ck9liM55TG3
YzHjNbcZHKfa8fcDgpIGL7A7altEfLyQVO3mLzoN60ISWBvt+qRuGkhjdIZOU6F6
9Sl1KgXxuW4oZCF7UZslM0ZHWwHB3DYKcOjFkXqpCqOUt38jWz5AX7HU4svFF923
ABzm1QtXAgMBAAECggEAZ6n8W5Yol8RYONsJh2W1Ew8K1nt3sqimbHkOEUDtfKRz
z6Gk2RYpvPTTQY8ERHYbGDLtJ+ksDLatzMOoyShgf5ZowfaEwv6EI3GC7PpEq0a0
Hcdo7yJBPz7ZzoUXye42rM6oDChyHEqcLxVi9QYIhm1Hswoz6JJn2YOimD63jI8O
bCUJvkj1RDnXo1Ps4ZFz9dCHPxwjSnPci86Xhoj6YTM8bu4P1Sckt9BOC02busi4
2esHJaltCZrUrWTV9WKGMR0JD1haLblKS9zFO9fxHadEXOdsue+LxbnorTlr4sM1
I9aXCn7v0GiuIM965YwOzzn29mXRtY6TQqEATJvmXQKBgQDuTuWwmONbfQ1yau5e
iWMK7877OH+mi+U33TpxEpTwMOmIbLSbx7fICylQ5/Kd83yhUlGDawUsNYNnIPlR
kBnW8RsoIdV8+9V9ClA5l3acDt3sCnAvnBq8CIcqoGbaneZh5u9YGuMJObut+v20
Fa619R1kmbMOhkHuqZ0F3neiJQKBgQDhL9uxjx5vDNJrh3blOVhwpLWHOoptmphS
izpomUzO5jpedW+FNOuXG6CjrbEh/zMYyNmB+ZX8vnJp83SawhiGZp8AsHKc2otB
H60HVjWUiR5nceiClc24MBwvwPzfV3/+TYG9ZcqKgtm0HlgCxaz4z9QNEL9QJohL
+TsdNnQYywKBgCPT7spvIfd2RJhIJVBHPYG+bhLs+pwSekK82vV3Ardd0y50kW6+
Rw4nR23ngV1n5vvmAWVNqLhtzzSpC3LMxGXBWADfnVYuEnm7HDacY/OwdILxSs6N
nKNacN/iv7Pse1+Ktb88Q5f2exX8Hzp87AhlMqcWSIpNewojq/ze5oOVAoGAJ60B
/V/lEdXlgTKl/S9EaNxsa34iA7u4WNrVGLbh9JZV9GymkIbJd59Th2NEEWRggV5q
DF+IULbRe998TQQjxBJys3FjUEWlQX0uRFupJxmdtMY6HD/+thQr8zICm+tTzt+j
G1bC//KcHwM1qI9hsZkUmJS50Ippe1FXXAdLH08CgYBO41JwRNJaZCoE3ybo3XKh
tbYCFT458nxl/ZrHZjr3kjUBZEimCluZAUlwIeEhQmzwug2Xf2VhK9yMWEKhuCde
NtEFaGPfi4wMI6uEgimdwdqxDiEFEZtjYcFOvClHVH9nAT7ZyYZzjOvpC+PJ1rPz
BYr/w9ucuC11rYllBCEkxQ==
-----END PRIVATE KEY-----
"""

val caBPem = """
-----BEGIN CERTIFICATE-----
MIIC/jCCAeagAwIBAgIUE20WHXyI7R9k+k0b5pmFmAcFZr0wDQYJKoZIhvcNAQEL
BQAwHzEdMBsGA1UEAwwUbHlyaWMtY2xpZW50LXRlc3QtY2EwHhcNMjYwNzE4MDAw
MDAwWhcNMzYwNzE1MDAwMDAwWjAfMR0wGwYDVQQDDBRseXJpYy1jbGllbnQtdGVz
dC1jYTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMmy+bDc0CGBhLwA
LUc6J45qLTogMZCjf7g8X1cnepfBmc9f49JRx+EWub4dkE8l6xmz8kS9yH5FvtZ3
AueK3oaHrXvIP3M8G2CSbW3Oswpu1pYHCa/iAHmhef4j2Lnp4qEw5iCmAHn8D7Mv
PRzNi8Zja3zPo72fZi6LR0Upfr+HEXwxA2kTaFKKfn7pOaVOtv9Rmb2OXMt2RTb6
Es1fq3KKBp8Aux6ssimJ8a0eFWgYiGez/chqFyzyVWEBU/3rHY1Wsa+tAH1Pyqqr
oOv5V1/Bun3Pt3esRyYfsWJBUvK9m6ySD69CfUEwEcaSKKNc4pFEKbNz0PHPbzUa
n1jrzpMCAwEAAaMyMDAwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUo7CO7QTr
fjBPTvP3j7WblFzX4LQwDQYJKoZIhvcNAQELBQADggEBAEdZ6X7P/lOtTFTuzKy0
H5qrkxCW1e8HCnGUgh68waRbqqgEjBamRaSb1O1KtkgYYAVYMFHxnIbG+hhvvchH
PlnbnLdZYsKsr2wFfwv1A+YRTEmwu/lm3g+wEV00t2oT4eWaTBdk9HJKSb7dnKa5
Vkbk1O49Mfzxp64SMNdU9cZRdsYwflv80OQ8/RFtZ+PyNGOJe3VvQlB78okLe/Dc
BMnlfOrfiYD1F+JtuDgdmxeqHWyeqiY1QHSfQDl1YNn9tJ5cLgeRCUr5xI9MR89P
MP5kdgJUV//c8xFE40VdH/1JFRkjpKGSwjqpqigQY6Of3pa45/RM5X3ZSuGCQErE
wyg=
-----END CERTIFICATE-----
"""

val wrongNameCertPem = """
-----BEGIN CERTIFICATE-----
MIIDEDCCAfigAwIBAgIUEtYLcsM6b5nT7tBaj021fSK4FdIwDQYJKoZIhvcNAQEL
BQAwHzEdMBsGA1UEAwwUbHlyaWMtY2xpZW50LXRlc3QtY2EwHhcNMjYwNzE4MDAw
MDAwWhcNMzYwNzE1MDAwMDAwWjAYMRYwFAYDVQQDDA1vdGhlci5leGFtcGxlMIIB
IjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlWFhhm1LzbUeYtiIh+ojRjj5
r3SQyiSpq+sMympZX5Spye72x5CiQy37LMCker8uVyxz1ARTPUKEgZfUZRK2N2k6
B6fjwtvS6K5I03htqFJ0OB+xA5mrSqMLTQWAroAHpmdCA5w1+Sg6fZY+uGdGvuGA
FyfWo8yI0jqhUExrqariha226+tX15nEGzMB7lbieu3UAnMc6Au7d/7no+d88KPb
OtBbSJ56SK+PXmCdeS6K+RvDs4nB8cvatmCLzUoWePkyGLO6NuCy2+m/j+JAsqki
vpvWZyNCZHkVdqIKo5T7A5buAV0DJ4EK6xtHEKTPHcSnYyck5figCNx5Q3NmPwID
AQABo0swSTAYBgNVHREEETAPgg1vdGhlci5leGFtcGxlMAwGA1UdEwEB/wQCMAAw
HwYDVR0jBBgwFoAUo7CO7QTrfjBPTvP3j7WblFzX4LQwDQYJKoZIhvcNAQELBQAD
ggEBAB2ViaZfZLsqbWkGMfr/jma4tMIf1+hLfIdkYyo3LNOs7RU4X51n87HwmxQJ
ycC1SBlC5JYKTP2uXbYCX/BqbDL4pBZAb/6HS2DKAUlchdndZjiIIJQ4RCLuTBrD
5/zIYQYzYpT86BmXdblT+mnf3LBCDr17WL8fJMDgm171/RmfpRHy4X+CInf5/JIg
9Q2GBeDpkhXBqEP6fsL99Efv1gWTZiTk1uF8TJwMf8i6vACMhfzvkHqiUEjz9OfO
kL4mPGGnih9lCyC8QC/LJC9avo7PpIAiL8d9rpT+50v+z8jmyICoXvdUWfj1sHZb
pfTHNoQWjJOKoiGh4B/eSWD+L4A=
-----END CERTIFICATE-----
"""

val wrongNameKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCVYWGGbUvNtR5i
2IiH6iNGOPmvdJDKJKmr6wzKallflKnJ7vbHkKJDLfsswKR6vy5XLHPUBFM9QoSB
l9RlErY3aToHp+PC29LorkjTeG2oUnQ4H7EDmatKowtNBYCugAemZ0IDnDX5KDp9
lj64Z0a+4YAXJ9ajzIjSOqFQTGupquKFrbbr61fXmcQbMwHuVuJ67dQCcxzoC7t3
/uej53zwo9s60FtInnpIr49eYJ15Lor5G8OzicHxy9q2YIvNShZ4+TIYs7o24LLb
6b+P4kCyqSK+m9ZnI0JkeRV2ogqjlPsDlu4BXQMngQrrG0cQpM8dxKdjJyTl+KAI
3HlDc2Y/AgMBAAECggEAGyF/tAmfzfHKXguT6JOW6ocomjxim8RC6M2dGhpstxZq
LBnxylczkV4Fk6A9f2m/wed59hT/BU5SgLMRyXW3kKLU/lT44ghI6yfUZEwoJn0r
TJI89TlwyfKI9+k68Pah7RAuBjfV+bXbwbmLFLT1PW/5crsymbdpVj191Pa8SylO
KwXodGZotbBGKOcN5BllFadzPqzZ6Gy0OJzf1Bpd5OVghfE3b2K12iEsvYsf0fU6
5ivhNIq2o/gCouSHQ5q/AZQuaOIWU6u/y2qxTou53gj08M/RNP9Ec1QJHQBoypo9
SgwpYdU97lEmeKNhenK/Am3kjlx9R61Egh24qLNo+QKBgQDO7a7CP5jVpuh3au+a
cxlBkoqmW4S92rcYS+KnY4zS2v4RMqMhELwqw6wLhd1U7QduF8vRp68Z62p9dhlX
jkoMvMGarew+raiGTqcUMDCadDcUe9gFT6KwWUeJ2qQ660cIH4FaFeyCooNnL2Xi
edYBQD5d0/FneGjUbkGbf07/UwKBgQC4zgq1vIqpVMgvvG6H0y1t/8wXsMeES+zD
68JBZEnYiNAQM/iMV14OztNoAAC/nAYlN14GTAiG+afUjbNRPCO0j05eKeGhetna
4q0tz0tELSLS4mr9365Of5R4CXko2G+AmHoSVso2rF5iKZIIWTTYjPXz9JKCFgmF
of+cWo/b5QKBgC/9YX09QJW0Ks+fJkhcjyvs72jbarKZKcNhvgPyC3PPRAL7Cmgd
uHX2gUz+07Dhc8qtjCBoUiyhs0W7gO8UWcoQcJoN4e87WQ0k6oy9DFiVwTxn6FZ6
/JEHc5bd9R6Q+B1DKT2aPgqh4/WnQWq/tMj/fDdIcwD7JNy3YVHNuaVvAoGBAJGK
izq3Qsi6oXGex7mmYYfYxUX/DhItrUha+sB/F/01Og8YruzvvX6R+kJUhkJgwSI8
KYtyA+Ew6rDl68vVPhVsKv7TowOGed39WP/T2mXV2jAU6sgHigH+TdH/O/EkCyRO
cQzSVyyZsTdDn+N9RbYpxWWcPmm+qz8X5vOfCt7VAoGAC3uNUBVr1t3o0+2jYG5q
6vKX3yXG9/QPTJY9au64s1Z1hs+vzaMUQYNGE/QczvBrVTm74WhECnfa2faIMTVa
vGMfPMEHEDlBW7S7ykqOKJbVlp+tlJWuhh5s15Pf0GbiC1aqD4qhmqn99YGENUx4
SK5AMRdP5Fd1geEfLp/YUNs=
-----END PRIVATE KEY-----
"""

val expiredCertPem = """
-----BEGIN CERTIFICATE-----
MIIDDjCCAfagAwIBAgIUHaMCt/LS7R6iWD4q6LqftdLZDrMwDQYJKoZIhvcNAQEL
BQAwHzEdMBsGA1UEAwwUbHlyaWMtY2xpZW50LXRlc3QtY2EwHhcNMjAwMTAxMDAw
MDAwWhcNMjAwMTAyMDAwMDAwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0G
CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC5wzngWxp9tK8bqFc0bTIvQSTl2tFo
fFki4/4+CRR964dXGbZ8YwopcQCogEYQboSJQDzoHTXSAwRVrRRMiAAuS5V6C9Qj
8799BNhOm9U40oUU6G6Y6WUMRrJGvzdSpETBqtjFTn8q3RyHbjzxPxRlBD1C62W+
GUkGlOIYfEG0TdLUytgOxPlMhscvD91miAJ6tArbSQ3KmSMdoD6+GXddnvmxEEXG
CavXGcno454fo6IAaZ94hjPiftko4BzFr5YY+am3Pf43O0a5Oxc3wUhPWzBaNykN
JBxN74R9S8bCjHQwZS4jPefYNg9di3bC1r7ap8tkeoi7l0hsHne4TJvNAgMBAAGj
TTBLMBoGA1UdEQQTMBGCCWxvY2FsaG9zdIcEfwAAATAMBgNVHRMBAf8EAjAAMB8G
A1UdIwQYMBaAFKOwju0E634wT07z94+1m5Rc1+C0MA0GCSqGSIb3DQEBCwUAA4IB
AQCkunV2xda9ScBe45Et8BPgN9WbsBwljfLcGeFzRMzjKagauEp8s22vaFr59PZl
WQ66Uph7CYEo8BPvdz79UfPpGSJRKmoeoBvOF8KctEaW0p0KWPIff8FnoOUhFoqu
JPm4Pvc6ICuSGfCP/ZsEDGgZrqentRleRZQjH9qFyBTJ1erq1qCmBcbU4h+PIErp
sQ7Wa8fYak+MatEhcRhH5zHdgAN3dqfdFGi+uE0gIVo7xKPKNjhDpm4GKmx7Fvfl
J0SeL0qxUPP0zpuWqJ5/NJX5+7BipAswm89GVFbbWUeMcxy98NFtNyIcy8MWA1oP
+biiC1zNThHBgxZhqQQvk01h
-----END CERTIFICATE-----
"""

val expiredKeyPem = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC5wzngWxp9tK8b
qFc0bTIvQSTl2tFofFki4/4+CRR964dXGbZ8YwopcQCogEYQboSJQDzoHTXSAwRV
rRRMiAAuS5V6C9Qj8799BNhOm9U40oUU6G6Y6WUMRrJGvzdSpETBqtjFTn8q3RyH
bjzxPxRlBD1C62W+GUkGlOIYfEG0TdLUytgOxPlMhscvD91miAJ6tArbSQ3KmSMd
oD6+GXddnvmxEEXGCavXGcno454fo6IAaZ94hjPiftko4BzFr5YY+am3Pf43O0a5
Oxc3wUhPWzBaNykNJBxN74R9S8bCjHQwZS4jPefYNg9di3bC1r7ap8tkeoi7l0hs
Hne4TJvNAgMBAAECggEAH1RStYkH7b2Ebui0VG46MYgOHgoKmVGngt/q6DGF2DrZ
55G5mj7l3tllIAYKSwkopzFDVG5gvlut5nk7XDDvvt8Wha/rBmk8mWwwwwk7K8st
kLomtPlgBnMB7DahsPltczBKQPSdM/B4uEqaUqGt4d+WKWwkC6yeCVMg0rpaJntT
tk3KAXCv+ekmpPF4Fgb4guLvx4+cX7IoTlPTaX+3ahRkl3BhqMQEoEu745yFciFS
MI/S9tVoHbPwuOoTSjuejfy72Z/1pCx8ABC0gv3jKcn6pO+oYYyqgumB0vIVzJiJ
MC4Ye8y29x/bXq7K+BqLHpse1rEDHBpW4u2cQIpxLQKBgQDwHJSjmkvNzH96jjKp
aCcUlyeky4RHe9PLAGq97muVdzE6cvrN5pqr9Q8sD8qgr4/+F2Nq6k4bLqo/kgIk
cR6ACH/z39Mb9j63WadPeU94mA5GtNrbWHpxThnTnmY62jnfboQ7VDZF/Kmb5QgH
Savv683eM97/vFbFedOwaVAkDwKBgQDGDf0sznYgTKd4B7hUdD6LsGAHmVY0dHcD
YSM2P3+J/DRicJNkn1qtm3v8bhtZ4ce17qzcUc5p1Vfj/HrKEgbjfVN5nT28kU50
K2D/aDrG5ize7J7QoXv4OnSDTWCbhodNAr8YPVGLfNjNRvHgM3C6A9pVR8Wrezkf
lDkmFJS2YwKBgQCkPhialGe33WNx1KTo5nqdBgwzGJdiQlyMZrudMeJbeg2teor+
nvg8GcQIEsE7CvxHBX6W2rEUvOXt2BUpEkuXrri/e+IvJVCfIG9m2Ic46WISkZGH
Ks2Ohar660Xoie++Wx2Oa7s4Qm1OWusT+RvoYHcQwJCQhCciq4PXDyKnlwKBgBMe
0J1dxUuy+sv8us/0dQFZYrv5Erh3sfGylAqtsKtqnMgQJDqno8J061BgdOWFhZlL
1IZko2/WN+j7vAL8IIwf0kpAYvBses1+Tpv5vQrst9JBt8def7BkPFFczAHXyAIo
TLiTWucDg4611a4WaUCcFJz9E9lNSSOCVM4XWJAPAoGAMDJgd9Qk6u7yWuXjMOAI
jtnWKVrdc73gzPNKwHp0YvXumhbRQElmodIqyMjgGuZJxtdI3W0iYkGzAA8ljZZo
vp0AzPjYy3PzG+uJftNeuHpHXsh/bZhxP4cE3J7Pok4ekSqUvAtyyV5s1SjYpnop
aRot9qh84DEYlwYii5oUetQ=
-----END PRIVATE KEY-----
"""

func taskRun(work: in () -> Unit): Task.Scope {
  val sc = Task.makeScope()
  Task.scopeSpawn(sc, work)
  sc
}

func serverIdentity(): Identity {
  match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Ok(id) -> id
    case Err(e) -> panic("server identity load failed: " + TlsError.message(e))
  }
}

func caCertificate(): Certificate {
  match Certificate.fromPem(caCertPem) {
    case Ok(c) -> c
    case Err(e) -> panic("ca load failed: " + TlsError.message(e))
  }
}

func clientIdentity(): Identity {
  match Identity.fromPem(clientCertPem, clientKeyPem) {
    case Ok(id) -> id
    case Err(e) -> panic("client identity load failed: " + TlsError.message(e))
  }
}

func httpOkResponse(body: in String): slice[Byte] {
  encodeUtf8(
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " + toString(body.length) +
      "\r\nConnection: close\r\n\r\n" +
      body
  )
}

// Bounded wait for the server task to signal it has started (`ready` is
// non-empty) before the client connects — replaces a fixed-duration
// `Time.sleepMillis`, which is a latent CI flake under slow scheduling (#6032).
// Correctness does not actually depend on this timing: the listener is bound
// (`hostListen` returns) BEFORE the server task is spawned, so a client
// connection always lands in the accept backlog and the TLS handshake / read
// blocks until the server task processes it. This poll only tightens the
// window (and lets the test fail fast if the task never starts). `ready` is
// written on the server thread and read here on the main thread; a torn read
// merely spins one more iteration, and the bound guarantees termination.
func waitReady(ready: in List[String], maxTries: in Int): Unit {
  var i = 0
  while i < maxTries and ready.count == 0 {
    Time.sleepMillis(50)
    i = i + 1
  }
}

// Accept one TLS connection, reply with a body echoing the negotiated ALPN,
// then close. Signals `ready` before blocking on accept. The handshake outcome
// is appended to `outcome` (read on the main thread after the scope is awaited, which is
// a memory barrier).
func serveOneTls(listener: in Listener, cfg: in TlsServerConfig, ready: in List[String], outcome: in List[String]): Unit {
  ready.add("go")
  match hostAcceptTls(listener, cfg) {
    case Err(e) -> outcome.add("ERR:" + TcpError.message(e))
    case Ok(conn) -> {
      outcome.add("OK:" + hostAlpn(conn))
      match hostRead(conn, 4096) {
        case Ok(_) -> {
          val _ = hostWrite(conn, httpOkResponse("alpn=" + hostAlpn(conn)));
          ()
        }
        case Err(_) -> ()
      }
      hostClose(conn)
    }
  }
}

func plainEchoServer(listener: in Listener, ready: in List[String]): Unit {
  ready.add("go")
  match hostAccept(listener) {
    case Err(_) -> ()
    case Ok(conn) -> {
      match hostRead(conn, 1024) {
        case Ok(bytes) -> {
          val _ = hostWrite(conn, bytes);
          ()
        }
        case Err(_) -> ()
      }
      hostClose(conn)
    }
  }
}

test "TcpError.message renders every case" {
  assertEqual(TcpError.message(BindFailed(message = "x")), "bind failed: x", "bind")
  assertEqual(TcpError.message(TlsHandshakeFailed(message = "x")), "TLS handshake failed: x", "tls")
  assertEqual(TcpError.message(TransportFailed(message = "x")), "I/O error: x", "io")
  assertEqual(TcpError.message(TlsConfigInvalid(message = "x")), "TLS configuration invalid: x", "config")
}

// `AcceptFailed` carries the accept errno and failure kind on native only
// (issue #6805), so its message is checked per target.
@cfg(not(target = "native"))
test "TcpError.message renders AcceptFailed" {
  assertEqual(TcpError.message(AcceptFailed(message = "x")), "accept failed: x", "accept")
}

@cfg(target = "native")
test "TcpError.message renders AcceptFailed" {
  assertEqual(
    TcpError.message(AcceptFailed(message = "x", errno = 0, kind = AcceptFatal)),
    "accept failed: x",
    "accept"
  )
}

test "hostListen rejects a malformed address as BindFailed" {
  match hostListen("not-an-ip", 18921) {
    case Ok(_) -> panic("expected BindFailed for a malformed address")
    case Err(e) -> match e {
      case BindFailed(_) -> assertTrue(true, "malformed address rejected")
      case _ -> panic("expected BindFailed, got " + TcpError.message(e))
    }
  }
}

test "plain loopback echo round trip" {
  val listener = match hostListen("127.0.0.1", 18921) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val ready: List[String] = newList()
  val server = taskRun({ -> plainEchoServer(listener, ready) })
  waitReady(ready, 100)
  val conn = match hostConnect("127.0.0.1", 18921, 0) {
    case Ok(c) -> c
    case Err(e) -> panic("connect failed: " + TcpError.message(e))
  }
  assertEqual(hostAlpn(conn), "", "a plain connection has no ALPN")
  val _ = hostWrite(conn, encodeUtf8("ping"))
  val echoed = match hostRead(conn, 1024) {
    case Ok(b) -> b
    case Err(e) -> panic("read failed: " + TcpError.message(e))
  }
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
  match tryDecodeUtf8(echoed) {
    case Some(s) -> assertEqual(s, "ping", "echo round trip returns the sent bytes")
    case None -> panic("echoed bytes were not valid UTF-8")
  }
}

test "server TLS terminates and round-trips bytes with an http/1.1 client" {
  val listener = match hostListen("127.0.0.1", 18922) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // Pin HTTP/1.1: the transport now advertises `h2` too (phase 4.4), and the
  // default h2-or-lower client would negotiate h2 — but `serveOneTls` is a raw
  // HTTP/1.1 echo server, not an h2 endpoint. (h2 end-to-end is covered by
  // `http_server_tests.l`.) A .NET HttpClient pinned to HTTP/1.1 sends no
  // ALPN extension, so the server negotiates no protocol and `hostAlpn` reports
  // `""` — this verifies the server correctly reports "no ALPN" and still
  // round-trips the raw bytes.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
      Http11
    )
  )
  val resp = match await client.get("https://localhost:18922/") {
    case Ok(r) -> r
    case Err(e) -> panic("client GET failed: " + HttpError.message(e))
  }
  val body: String = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "TLS-terminated response carries the 200 status")
  assertTrue(body.startsWith("alpn="), "server echoed its ALPN report over the TLS byte round trip: " + body)
  assertTrue(not body.contains("alpn=h2"), "an http/1.1-pinned client is not served as h2: " + body)
}

test "mTLS accepts a client whose certificate chains to clientCa" {
  val listener = match hostListen("127.0.0.1", 18923) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // Pin HTTP/1.1 (see the http/1.1 round-trip test): `serveOneTls` speaks raw
  // HTTP/1.1, so the default h2-or-lower client (which would now negotiate the
  // newly-advertised h2) must pin http/1.1 here.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withClientIdentity(
        HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
        clientIdentity()
      ),
      Http11
    )
  )
  val result = await client.get("https://localhost:18923/")
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
  match result {
    case Ok(r) -> assertEqualInt(r.statusCode(), 200, "mTLS client accepted; 200 returned")
    case Err(e) -> panic("mTLS accept: client GET failed: " + HttpError.message(e))
  }
}

test "mTLS rejects a client presenting no certificate when requireClientCert is set" {
  val listener = match hostListen("127.0.0.1", 18924) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // No client identity -> the server must reject the handshake.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate())
  )
  val result = await client.get("https://localhost:18924/")
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
  assertTrue(outcome[0].startsWith("ERR"), "server rejected the certless client at the handshake: " + outcome[0])
  match result {
    case Ok(_) -> panic("expected the client GET to fail against a rejecting mTLS server")
    case Err(_) -> assertTrue(true, "client GET failed as expected")
  }
}

// #6042: requireClientCert with no clientCa is a mutual-TLS misconfiguration —
// without a client CA to pin trust to, the kernel would otherwise fall back to
// the system trust store and accept any publicly-trusted client certificate.
// hostAcceptTls must reject it up front (before any accept), so no client or
// background task is needed here.
test "mTLS config with requireClientCert but no clientCa is rejected as invalid" {
  val listener = match hostListen("127.0.0.1", 18925) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = true)
  val result = hostAcceptTls(listener, cfg)
  hostStopListener(listener)
  match result {
    case Ok(_) -> panic("expected TlsConfigInvalid for requireClientCert without clientCa")
    case Err(e) -> match e {
      case TlsConfigInvalid(_) -> assertTrue(true, "mTLS misconfiguration rejected before any accept")
      case _ -> panic("expected TlsConfigInvalid, got " + TcpError.message(e))
    }
  }
}

// #6033: exercise the Tls13 branch of buildServerOptions (minVersion = Tls13
// pins EnabledSslProtocols to TLS 1.3). The real Lyric HTTPS client negotiates
// TLS 1.3 with a 1.3-only server, so the handshake + round trip still succeed.
test "TLS 1.3 minVersion still completes the handshake and round trip" {
  val listener = match hostListen("127.0.0.1", 18926) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls13, clientCa = None, requireClientCert = false)
  val outcome: List[String] = newList()
  val ready: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)

  // Pin HTTP/1.1 (see the http/1.1 round-trip test): raw `serveOneTls` + the
  // newly-advertised h2 would otherwise negotiate h2 against a non-h2 server.
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
      Http11
    )
  )
  val resp = match await client.get("https://localhost:18926/") {
    case Ok(r) -> r
    case Err(e) -> panic("client GET failed under Tls13: " + HttpError.message(e))
  }
  val body: String = match await resp.bodyText() { case Ok(t) -> t; case Err(_) -> panic("response body read failed") }
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
  assertEqualInt(resp.statusCode(), 200, "Tls13 server completes the round trip with 200")
  assertTrue(body.startsWith("alpn="), "Tls13 server echoed its ALPN report over the round trip: " + body)
  assertTrue(not body.contains("alpn=h2"), "an http/1.1-pinned client is not served as h2 under Tls13: " + body)
}

// Accept one TLS connection, read its request, then block in a second read
// (the client waits for a response and sends nothing); `blocked` is signalled
// just before that read and the second read's outcome is appended to
// `outcome`. The connection is published in `conns` for the thread that shuts
// it down.
func serveThenBlockInRead(
  listener: in Listener,
  cfg: in TlsServerConfig,
  conns: in List[Conn],
  blocked: in List[String],
  outcome: in List[String],
): Unit {
  match hostAcceptTls(listener, cfg) {
    case Err(e) -> outcome.add("handshake:" + TcpError.message(e))
    case Ok(conn) -> {
      conns.add(conn)
      match hostRead(conn, 4096) {
        case Err(e) -> outcome.add("first-read:" + TcpError.message(e))
        case Ok(_) -> {
          blocked.add("go")
          match hostRead(conn, 4096) {
            case Ok(chunk) -> outcome.add("read:" + chunk.length.toString())
            case Err(_) -> outcome.add("error")
          }
        }
      }
      hostClose(conn)
      // A client may retry an idempotent request on a new connection once the
      // first one ended without a response; stopping the listener refuses or
      // resets that retry, so the request fails instead of waiting for an
      // accept that never comes.
      hostStopListener(listener)
    }
  }
}

test "hostShutdown ends a read blocked on a TLS connection from another thread" {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val port = hostLocalPort(listener)
  val cfg = TlsServerConfig(identity = serverIdentity(), minVersion = Tls12, clientCa = None, requireClientCert = false)
  val conns: List[Conn] = newList()
  val blocked: List[String] = newList()
  val outcome: List[String] = newList()
  val server = taskRun({ -> serveThenBlockInRead(listener, cfg, conns, blocked, outcome) })
  val shutter = taskRun(
    { -> waitReady(blocked, 200); Time.sleepMillis(300); if conns.count > 0 { hostShutdown(conns[0]) } }
  )
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withHttpVersion(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), caCertificate()),
      Http11
    )
  )
  val started = Time.monotonicNanos()
  // The server never answers; the shutdown resets the connection, so the
  // request fails promptly instead of waiting out the client's own timeout.
  match await client.get("https://localhost:" + port.toString() + "/") {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val _ = await Task.awaitAll(shutter)
  val _2 = await Task.awaitAll(server)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  hostStopListener(listener)
  assertEqualInt(blocked.count, 1, "the server reached its blocking read")
  assertEqualInt(outcome.count, 1, "the blocked TLS read returned")
  assertTrue(
    outcome[0] == "read:0" or outcome[0] == "error",
    "a shut-down TLS read is end of stream or an error: " + outcome[0]
  )
  assertTrue(elapsedMs < 20000i64, "the shutdown ended the exchange promptly: " + elapsedMs.toString() + " ms")
}

// ---------------------------------------------------------------------------
// Client TLS (docs/72 slice 4): `hostConnectTls` / `hostUpgradeClientTls`
// against the kernel's own server side.
// ---------------------------------------------------------------------------
func identityFrom(certPem: in String, keyPem: in String): Identity {
  match Identity.fromPem(certPem, keyPem) {
    case Ok(id) -> id
    case Err(e) -> panic("identity load failed: " + TlsError.message(e))
  }
}

// A one-shot TLS server (`serveOneTls`) on an ephemeral port.
record Probe {
  listener: Listener
  port: Int
  ready: List[String]
  outcome: List[String]
  server: Task.Scope
}

func startProbe(cfg: in TlsServerConfig): Probe {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val port = hostLocalPort(listener)
  val ready: List[String] = newList()
  val outcome: List[String] = newList()
  val server = taskRun({ -> serveOneTls(listener, cfg, ready, outcome) })
  waitReady(ready, 100)
  Probe(listener = listener, port = port, ready = ready, outcome = outcome, server = server)
}

func finishProbe(p: in Probe): Unit {
  val _ = await Task.awaitAll(p.server)
  hostStopListener(p.listener)
}

func serverCfg(certPem: in String, keyPem: in String): TlsServerConfig {
  TlsServerConfig(identity = identityFrom(certPem, keyPem))
}

func exclusive(pem: in String): TlsClientTrust {
  TlsTrustExclusive(caPem = pem)
}

// Write a request and read the server's response as text.
func exchange(conn: in Conn): String {
  val _ = hostWrite(conn, encodeUtf8("ping"))
  match hostRead(conn, 4096) {
    case Ok(b) -> match tryDecodeUtf8(b) { case Some(t) -> t; case None -> panic("response was not valid UTF-8") }
    case Err(e) -> panic("read failed: " + TcpError.message(e))
  }
}

func expectHandshakeFailure(result: in Result[Conn, TcpError], what: in String): String {
  match result {
    case Ok(conn) -> {
      hostClose(conn)
      panic(what + ": the handshake was expected to fail but succeeded")
    }
    case Err(e) -> match e {
      case TlsHandshakeFailed(m) -> m
      case _ -> panic(what + ": expected TlsHandshakeFailed, got " + TcpError.message(e))
    }
  }
}

func connectOk(result: in Result[Conn, TcpError], what: in String): Conn {
  match result {
    case Ok(c) -> c
    case Err(e) -> panic(what + ": connect failed: " + TcpError.message(e))
  }
}

test "client TLS: a pinned CA verifies the server certificate and bytes round-trip" {
  val p = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val conn = connectOk(hostConnectTls("localhost", p.port, exclusive(caCertPem), None, Tls12, "", 5000), "pinned CA")
  assertEqual(hostAlpn(conn), "", "no ALPN offered, none negotiated")
  val body = exchange(conn)
  hostClose(conn)
  finishProbe(p)
  assertTrue(body.contains("alpn="), "the server answered over the client TLS connection: " + body)
  assertEqual(p.outcome[0], "OK:", "the server completed the handshake and saw no ALPN")
}

test "client TLS: ALPN h2 is negotiated when both sides offer it, and the server saw the same" {
  val p = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val conn = connectOk(
    hostConnectTls("localhost", p.port, exclusive(caCertPem), None, Tls12, "h2,http/1.1", 5000),
    "alpn h2"
  )
  val alpn = hostAlpn(conn)
  val body = exchange(conn)
  hostClose(conn)
  finishProbe(p)
  assertEqual(alpn, "h2", "the preferred protocol is selected")
  assertEqual(p.outcome[0], "OK:h2", "the server negotiated the same protocol")
  assertTrue(body.contains("alpn=h2"), "the server's reply reports h2: " + body)
}

test "client TLS: a client offering only http/1.1 is served http/1.1" {
  val p = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val conn = connectOk(
    hostConnectTls("localhost", p.port, exclusive(caCertPem), None, Tls12, " http/1.1 ", 5000),
    "alpn http/1.1"
  )
  val alpn = hostAlpn(conn)
  hostClose(conn)
  finishProbe(p)
  assertEqual(alpn, "http/1.1", "a padded entry in the offer list is trimmed")
  assertEqual(p.outcome[0], "OK:http/1.1", "the server negotiated http/1.1")
}

test "client TLS: an offer with no overlap negotiates no protocol or fails, never a protocol nobody offered" {
  val p = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val result = hostConnectTls("localhost", p.port, exclusive(caCertPem), None, Tls12, "spdy/3", 5000)
  match result {
    case Ok(conn) -> {
      assertEqual(hostAlpn(conn), "", "an unoffered protocol is never reported")
      hostClose(conn)
    }
    case Err(e) -> match e {
      case TlsHandshakeFailed(_) -> assertTrue(true, "the server refused the offer")
      case _ -> panic("expected a handshake outcome, got " + TcpError.message(e))
    }
  }
  finishProbe(p)
}

test "client TLS: a certificate valid for another name is refused (hostname verification)" {
  // The chain verifies against the pinned CA; only the name is wrong, so a
  // refusal here is the hostname check and nothing else.
  val p = startProbe(serverCfg(wrongNameCertPem, wrongNameKeyPem))
  val reason = expectHandshakeFailure(
    hostConnectTls("localhost", p.port, exclusive(caBPem), None, Tls12, "", 5000),
    "wrong name"
  )
  finishProbe(p)
  assertTrue(reason.length > 0, "the failure carries the platform's reason")
}

test "client TLS: the name verified is the SNI host, not the dial host" {
  val p = startProbe(serverCfg(wrongNameCertPem, wrongNameKeyPem))
  val plain = match hostConnect("127.0.0.1", p.port, 5000) {
    case Ok(c) -> c
    case Err(e) -> panic("connect failed: " + TcpError.message(e))
  }
  val conn = connectOk(hostUpgradeClientTls(plain, "other.example", exclusive(caBPem), None, Tls12, ""), "sni host")
  hostClose(conn)
  finishProbe(p)
  assertEqual(p.outcome[0], "OK:", "dialled by address, verified against the name the caller gave")
}

test "client TLS: an expired certificate is refused" {
  val p = startProbe(serverCfg(expiredCertPem, expiredKeyPem))
  val reason = expectHandshakeFailure(
    hostConnectTls("localhost", p.port, exclusive(caBPem), None, Tls12, "", 5000),
    "expired"
  )
  finishProbe(p)
  assertTrue(reason.length > 0, "the failure carries the platform's reason")
}

test "client TLS: a certificate from an untrusted CA is refused" {
  val p = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val reason = expectHandshakeFailure(
    hostConnectTls("localhost", p.port, exclusive(caBPem), None, Tls12, "", 5000),
    "untrusted"
  )
  finishProbe(p)
  assertTrue(reason.length > 0, "the failure carries the platform's reason")
}

test "client TLS: the system trust store does not trust the test CA" {
  val p = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val reason = expectHandshakeFailure(
    hostConnectTls("localhost", p.port, TlsTrustSystemDefault, None, Tls12, "", 5000),
    "system default"
  )
  finishProbe(p)
  assertTrue(reason.length > 0, "the failure carries the platform's reason")
}

test "client TLS: exclusive trust ignores the platform store, additive trust adds to it" {
  val p1 = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val ok = connectOk(
    hostConnectTls("localhost", p1.port, TlsTrustAdditive(caPem = caCertPem), None, Tls12, "", 5000),
    "additive CA"
  )
  hostClose(ok)
  finishProbe(p1)
  assertEqual(p1.outcome[0], "OK:", "a server signed by the additive CA is trusted")

  val p2 = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val reason = expectHandshakeFailure(
    hostConnectTls("localhost", p2.port, TlsTrustAdditive(caPem = caBPem), None, Tls12, "", 5000),
    "additive wrong CA"
  )
  finishProbe(p2)
  assertTrue(reason.length > 0, "an additive CA that did not sign the server does not make it trusted")
}

test "client TLS: an mTLS client presents its identity, and a client without one is refused" {
  val cfg = TlsServerConfig(
    identity = serverIdentity(),
    minVersion = Tls12,
    clientCa = Some(value = caCertificate()),
    requireClientCert = true
  )
  val p1 = startProbe(cfg)
  val conn = connectOk(
    hostConnectTls(
      "localhost",
      p1.port,
      exclusive(caCertPem),
      Some(value = clientIdentity()),
      Tls12,
      "",
      5000
    ),
    "mTLS identity"
  )
  val body = exchange(conn)
  hostClose(conn)
  finishProbe(p1)
  assertEqual(p1.outcome[0], "OK:", "the server accepted the presented client certificate")
  assertTrue(body.contains("alpn="), "the exchange completed after the mTLS handshake: " + body)

  val p2 = startProbe(cfg)
  val bare = hostConnectTls("localhost", p2.port, exclusive(caCertPem), None, Tls12, "", 5000)
  match bare {
    case Ok(c) -> hostClose(c)
    case Err(_) -> ()
  }
  finishProbe(p2)
  assertTrue(
    p2.outcome[0].startsWith("ERR"),
    "the server rejected the client that presented no certificate: " + p2.outcome[0]
  )
}

test "client TLS: a minimum version of TLS 1.3 still completes the handshake" {
  val p = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val conn = connectOk(hostConnectTls("localhost", p.port, exclusive(caCertPem), None, Tls13, "", 5000), "tls 1.3")
  val body = exchange(conn)
  hostClose(conn)
  finishProbe(p)
  assertTrue(body.contains("alpn="), "round trip under TLS 1.3: " + body)
}

test "client TLS: a malformed trust PEM is a rejected configuration and releases the socket" {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val port = hostLocalPort(listener)
  val ready: List[String] = newList()
  val seen: List[String] = newList()
  val server = taskRun(
    { ->
      ready.add("go")
      match hostAccept(listener) {
        case Err(e) -> seen.add("accept:" + TcpError.message(e))
        case Ok(c) -> {
          match hostRead(c, 1024) {
            case Ok(b) -> seen.add("read:" + b.length.toString())
            case Err(_) -> seen.add("read:error")
          }
          hostClose(c)
        }
      }
    }
  )
  waitReady(ready, 100)
  val plain = match hostConnect("127.0.0.1", port, 5000) {
    case Ok(c) -> c
    case Err(e) -> panic("connect failed: " + TcpError.message(e))
  }
  val result = hostUpgradeClientTls(plain, "localhost", exclusive("not a certificate"), None, Tls12, "")
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
  match result {
    case Ok(c) -> {
      hostClose(c)
      panic("expected TlsConfigInvalid for a malformed trust PEM")
    }
    case Err(e) -> match e {
      case TlsConfigInvalid(_) -> assertTrue(true, "malformed trust PEM rejected")
      case _ -> panic("expected TlsConfigInvalid, got " + TcpError.message(e))
    }
  }
  assertEqual(seen[0], "read:0", "the plain socket was closed, so the server read end of stream")
}

test "client TLS: a failed handshake releases the socket and a refused connect is a transport failure" {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val port = hostLocalPort(listener)
  hostStopListener(listener)
  match hostConnectTls("127.0.0.1", port, exclusive(caCertPem), None, Tls12, "", 2000) {
    case Ok(c) -> {
      hostClose(c)
      panic("expected the connect to a closed port to fail")
    }
    case Err(e) -> match e {
      case TransportFailed(_) -> assertTrue(true, "a refused connect is a transport failure")
      case _ -> panic("expected TransportFailed, got " + TcpError.message(e))
    }
  }
}

test "client TLS: the insecure trust decision accepts a certificate for another name and an expired one" {
  val p1 = startProbe(serverCfg(wrongNameCertPem, wrongNameKeyPem))
  val c1 = connectOk(
    hostConnectTls("localhost", p1.port, TlsTrustInsecure, None, Tls12, "", 5000),
    "insecure wrong name"
  )
  hostClose(c1)
  finishProbe(p1)
  assertEqual(p1.outcome[0], "OK:", "a certificate for another name is accepted when verification is off")

  val p2 = startProbe(serverCfg(expiredCertPem, expiredKeyPem))
  val c2 = connectOk(hostConnectTls("localhost", p2.port, TlsTrustInsecure, None, Tls12, "", 5000), "insecure expired")
  hostClose(c2)
  finishProbe(p2)
  assertEqual(p2.outcome[0], "OK:", "an expired certificate is accepted when verification is off")

  val p3 = startProbe(serverCfg(serverCertPem, serverKeyPem))
  val c3 = connectOk(
    hostConnectTls("localhost", p3.port, TlsTrustInsecure, None, Tls12, "", 5000),
    "insecure untrusted"
  )
  hostClose(c3)
  finishProbe(p3)
  assertEqual(p3.outcome[0], "OK:", "a certificate from an unknown CA is accepted when verification is off")
}

// ---------------------------------------------------------------------------
// `hostReadDeadline`: a deadline-bounded read (docs/72 slice 4b).
// ---------------------------------------------------------------------------
// Accept one connection (TLS when `cfg` is given), wait until `gate` is
// non-empty, send "late", then wait for the peer to close.
func serveAfterGate(
  listener: in Listener,
  cfg: in Option[TlsServerConfig],
  ready: in List[String],
  gate: in List[String],
): Unit {
  ready.add("go")
  val accepted = match cfg { case Some(c) -> hostAcceptTls(listener, c); case None -> hostAccept(listener) }
  match accepted {
    case Err(_) -> ()
    case Ok(conn) -> {
      var i = 0
      while i < 400 and gate.count == 0 {
        Time.sleepMillis(25)
        i = i + 1
      }
      val _ = hostWrite(conn, encodeUtf8("late"))
      val _2 = hostRead(conn, 16)
      hostClose(conn)
    }
  }
}

func millisSince(startNanos: in Long): Long {
  (Time.monotonicNanos() - startNanos) / 1000000i64
}

func assertDeadlineThenData(conn: in Conn, gate: in List[String], what: in String): Unit {
  val started = Time.monotonicNanos()
  val first = hostReadDeadline(conn, 64, started + 150000000i64)
  val waited = millisSince(started)
  match first {
    case Ok(b) -> panic(what + ": expected the deadline to pass, read " + b.length.toString() + " bytes")
    case Err(e) -> match e {
      case ReadDeadlinePassed -> assertTrue(true, what + ": the deadline passed")
      case ReadFailed(inner) -> panic(
        what + ": expected ReadDeadlinePassed, got " + TcpError.message(inner)
      )
    }
  }
  assertTrue(waited >= 100i64, what + ": the read waited for the deadline: " + waited.toString() + " ms")
  assertTrue(waited < 5000i64, what + ": the read did not wait far past the deadline: " + waited.toString() + " ms")
  gate.add("go")
  val second = hostReadDeadline(conn, 64, Time.monotonicNanos() + 5000000000i64)
  match second {
    case Ok(b) -> match tryDecodeUtf8(b) {
      case Some(t) -> assertEqual(
        t,
        "late",
        what + ": the connection is intact after a deadline: no bytes lost"
      )
      case None -> panic(what + ": bytes were not valid UTF-8")
    }
    case Err(e) -> panic(what + ": the read after a passed deadline failed: " + ReadDeadlineError.message(e))
  }
}

test "hostReadDeadline on a plain connection: the deadline passes, the connection stays usable" {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val port = hostLocalPort(listener)
  val ready: List[String] = newList()
  val gate: List[String] = newList()
  val server = taskRun({ -> serveAfterGate(listener, None, ready, gate) })
  waitReady(ready, 100)
  val conn = connectOk(hostConnect("127.0.0.1", port, 5000), "plain")
  assertDeadlineThenData(conn, gate, "plain")
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
}

test "hostReadDeadline on a TLS connection: the deadline passes, the connection stays usable" {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val port = hostLocalPort(listener)
  val ready: List[String] = newList()
  val gate: List[String] = newList()
  val cfg = serverCfg(serverCertPem, serverKeyPem)
  val server = taskRun({ -> serveAfterGate(listener, Some(value = cfg), ready, gate) })
  waitReady(ready, 100)
  val conn = connectOk(hostConnectTls("localhost", port, exclusive(caCertPem), None, Tls12, "", 5000), "tls")
  assertDeadlineThenData(conn, gate, "tls")
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
}

test "hostReadDeadline with no deadline reads like hostRead, and sees end of stream" {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(e) -> panic("listen failed: " + TcpError.message(e))
  }
  val port = hostLocalPort(listener)
  val ready: List[String] = newList()
  val gate: List[String] = newList()
  gate.add("go")
  val server = taskRun({ -> serveAfterGate(listener, None, ready, gate) })
  waitReady(ready, 100)
  val conn = connectOk(hostConnect("127.0.0.1", port, 5000), "plain")
  val first = match hostReadDeadline(conn, 64, 0i64) {
    case Ok(b) -> b
    case Err(e) -> panic("read failed: " + ReadDeadlineError.message(e))
  }
  assertEqualInt(first.length, 4, "an unbounded read returns the bytes that arrive")
  // The server now waits for this side to close; closing it ends the exchange.
  hostClose(conn)
  val _ = await Task.awaitAll(server)
  hostStopListener(listener)
}
