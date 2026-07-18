//! tests/serve_tls_tests.l — dotnet end-to-end + target-neutral tests for
//! lyric-web's TLS server surface (docs/61 §6.3, phase 3.4 of epic #5874,
//! issue #5885).
//!
//! Since phase 3.4, `Web.serveTls` terminates TLS for real on `--target
//! dotnet` via `Std.HttpServer.startListenerTls` (the pure-Lyric sans-IO
//! `Std.HttpEngine` over the `Std.TcpHost` `TcpListener`/`SslStream`
//! transport that replaced `HttpListener`).  This suite drives a REAL
//! `Web.serveTls` listener with the REAL Lyric HTTPS client
//! (`HttpClientBuilder`, #5877) in-process and asserts the round trip,
//! including mTLS (dotnet supports it; the JVM Undertow listener does not
//! yet — that path is exercised by `tests/jvm_server_smoke.l`).
//!
//! dotnet-only e2e: the in-process loopback needs the blocking `Web.serveTls`
//! accept loop and the client to run on separate OS threads (Lyric `spawn` is
//! degenerate-synchronous on `--target dotnet`, D119/D120), so the server runs
//! on a `System.Threading.Tasks.Task`.  Declaring those `extern`s in a test
//! file mirrors `stdlib/tests/tcp_host_tls_tests.l` — a documented test-only
//! exception to the `_kernel/`-only extern rule for driving the opposite side
//! of a real protocol.  `Web.serveTls` blocks forever once bound, so each
//! server task is started and left running (the bounded client poll below
//! tolerates the async bind); the test process reclaims the threads/ports on
//! exit.  Distinct ports per test keep the listeners independent.
//!
//! The target-neutral surface (`ServeTlsError.message`, the `WebTls` config
//! template + its env-var override, and `tlsServerConfigFromWebTls`'s success
//! and file-not-found paths, all backed by `Std.Tls`) is exercised without a
//! socket.
@test_module
package Web.ServeTlsTests

import Std.Core
import Std.Collections
import Std.String
import Std.Tls
import Std.Http
import Std.File
import Std.Environment as Env
import Web
import Std.Testing

// A self-signed RSA-2048 server cert with SAN DNS:localhost,IP:127.0.0.1 (so
// the Lyric client's hostname check passes for https://localhost) plus its
// unencrypted PKCS8 key.  Self-signed, so the client trusts it directly as its
// own CA.  Test-only, no secret value.
val certPem = """-----BEGIN CERTIFICATE-----
MIIDNTCCAh2gAwIBAgIUb4NMb9lelfz9FhkutEWaItQgtmgwDQYJKoZIhvcNAQEL
BQAwHDEaMBgGA1UEAwwRbHlyaWMtdGVzdC1zZXJ2ZXIwHhcNMjYwNzE4MDczMDA2
WhcNMzYwNzE1MDczMDA2WjAcMRowGAYDVQQDDBFseXJpYy10ZXN0LXNlcnZlcjCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALlQ6kMPMzH5HawqSRL83fUc
8bIbxmEnu9Mr4sUYq7QZhizddj7slYwXoOsLkU/LFbGD39uwpNrpqsAZmvTs9BBa
NAQQNxJAMOIPAxI7HULQXrb+z2FDKkwhXR3Rp9YoHjgaNpwaCuzbI2LxtnJAiVcp
AJ5moTcz5ALgZyyQ2D/Z/IvJPQZnEAF0GnVM+JG/yg+3dqN+9Blu9JaZWgK6IfG3
7pEVvmYPpdNkc+1pWCDRG26MqNezo3JviJHlyfnnGhkeJLIxt3N4eUoYwf/KA8jV
2I9zCgcQGGPljAJuKe1cWEgSaH7XZAq+5eEQumx7DaYvdNtXz4NTnVxfvGXJ6fMC
AwEAAaNvMG0wHQYDVR0OBBYEFL9/OZMVlv9mWuYIUpF4icpjcSB1MB8GA1UdIwQY
MBaAFL9/OZMVlv9mWuYIUpF4icpjcSB1MA8GA1UdEwEB/wQFMAMBAf8wGgYDVR0R
BBMwEYcEfwAAAYIJbG9jYWxob3N0MA0GCSqGSIb3DQEBCwUAA4IBAQA/1GMpM+17
ITrUjDRYRWFMvpSNMDzrKifG2pZbwRWpjmVMQlJf3OVif/Qlvb8mPsxWArlQGRrH
OsHdwa9JUzpRoptNVQf63d8SFz4VHcMIF3h/9Iq88LjXMV1MyiObVZLLOAiiSW+j
piF0DjxFPTuCe5WB5VKUUwOtEEN9xIg5W1LNgWK0dvKwAScUiqG1qVPk9WD6IlYW
lbcCkesNrKyWmR4OYe2Cg3ZuXo6Tbd54/kfOFF5/LTRpYZVt7w2pzGX23y4/grrd
glYQptAz1EEgWcpiSkgIVZEBjIntcMrlPE6XDiRDkZovezHMBno47l0w3CgcYXSK
9pV5q75Q4+gt
-----END CERTIFICATE-----"""

val keyPem = """-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC5UOpDDzMx+R2s
KkkS/N31HPGyG8ZhJ7vTK+LFGKu0GYYs3XY+7JWMF6DrC5FPyxWxg9/bsKTa6arA
GZr07PQQWjQEEDcSQDDiDwMSOx1C0F62/s9hQypMIV0d0afWKB44GjacGgrs2yNi
8bZyQIlXKQCeZqE3M+QC4GcskNg/2fyLyT0GZxABdBp1TPiRv8oPt3ajfvQZbvSW
mVoCuiHxt+6RFb5mD6XTZHPtaVgg0RtujKjXs6Nyb4iR5cn55xoZHiSyMbdzeHlK
GMH/ygPI1diPcwoHEBhj5YwCbintXFhIEmh+12QKvuXhELpsew2mL3TbV8+DU51c
X7xlyenzAgMBAAECggEAB3+6uxP2YmNOTBU598a7xJtzPF3bXTsaYqU3+/nPmO4f
e9lKW6l/M7gRDvHc43m4WwKXIHC5exJRkox2tMqR5ceAq1lsoRRv5fXtjeNOf9Gm
w4j0I19warw+5GIDhKsC7gpBg3eaUZNcjzhwxZbO9/P0znQgufcjluo1wpvp5EuA
Q+oQBGjIEpaeMeYE7E/iZbddWHh5g4ESa31CMmDMjWkEEnZC4SaSLs/kKAQ+P36N
JgEpqoxhsOnoSEtsU8r3oPbC1+mBZXWNF+DJFvN/h9V0rVnnPjoPFpmyrGUNFeRB
rOUkzoIEVyqbPGjmUzsxs23Eg82sBo77sYEy7aTroQKBgQDjQQO7jSNgOqzk0/5V
GAU/uZF5je3zk+dlwD00BKhHNdm1P+F1O82m/x4BPgYwo933ZmwCjLS5q2ybkI2P
m49sfSx8UZCQuUMUiCX989UKDp1UBqzw0WquF9Uyse1g457go7VOly3FoGGO4iWY
RM5u61vu3o1OdLDVdhszl0XThQKBgQDQwdvoVIFrflA1MbJfSu4E+CZ3HX/SMFUt
GAgyYiw2zd1O/ZOHY0OasI01TOMg8wbFYLZ/UoVC2M/Xjk7mp8YqVXBTLBU/igty
IkxAykJYx0D2jlELrsNn6q9PEr/3eZYf4Xw2gv9zDi7F6IKds7DHBQNofYuVHQSj
jogQcqIVFwKBgQCfkg1O6oHGlizE2N6jXaSB5Ilzsuc8u8QlvGC9X+/RYMyn6l0j
doSnGEg3UxgBm27Gw1JgT/Cu1uICMfRUvERvR02vVY6PMKcbiaYztb0HvM9YKv/Q
cRvZdr6rRCiMeggbcJhkwN7RABbAv6bqTpYtaHI7PmY2itWIbdAX38aWCQKBgQC3
3shO7n+/qlYDRG6TuG/FOLzIldcLzz52pYAywH2pF9IhzP+wdCILkg4OMFatouEH
4JNdudVed5E5j0K3rnbAuthgqadde71xHfyD5KJjh70UbW29GIVMdk1LHHyxAQrV
scmySdeuA4P3FUBWnvrJkQTbeBkFkbWQSe5WbmGMqQKBgBkqMpYI7ee8fxtyZk9S
3K4yzZ3/tw97kXSwTbFm61LXWm1BhOCBawKZ5Cz3uUdLHFgZHxlp40DmooELd8pt
hYdhFWFd5WL7G9O4auVFYU6cSdrQ57iEjyhk9iT/xuPgFC5YIMiJY7pBvyBOBcU1
4A8NKn86cmQezL3EpOkMqP2Q
-----END PRIVATE KEY-----"""

// A self-signed CA, a server leaf (SAN DNS:localhost,IP:127.0.0.1) signed by
// it, and a client leaf signed by the same CA — for the mTLS-accept round trip
// (the client presents a cert that chains to the server's `clientCa`).  Same
// fixtures as `stdlib/tests/tcp_host_tls_tests.l`; test-only, no secret value.
val caCertPem = """-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----"""

val serverCertPem = """-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----"""

val serverKeyPem = """-----BEGIN PRIVATE KEY-----
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
-----END PRIVATE KEY-----"""

val clientCertPem = """-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----"""

val clientKeyPem = """-----BEGIN PRIVATE KEY-----
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
-----END PRIVATE KEY-----"""

// `Task.Run(Action)` on a background thread gives the in-process loopback the
// real concurrency `spawn` cannot on this target (see the module header). The
// Lyric `() -> Unit` closure binds to `System.Action` through the D122 delegate
// bridge, exactly as the transport-kernel test `tcp_host_tls_tests.l` does.
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

func fixtureConfig(): Std.Tls.TlsServerConfig {
  match Identity.fromPem(certPem, keyPem) {
    case Ok(id) -> TlsServerConfig(identity = id, minVersion = Tls12, clientCa = None, requireClientCert = false)
    case Err(e) -> panic("fixture identity load failed: " + TlsError.message(e))
  }
}

// mTLS config: server leaf signed by the CA, pins client trust to that CA and
// requires a client certificate.
func mtlsConfig(): Std.Tls.TlsServerConfig {
  val id = match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Ok(i) -> i
    case Err(e) -> panic("mTLS server identity load failed: " + TlsError.message(e))
  }
  val ca = match Certificate.fromPem(caCertPem) {
    case Ok(c) -> c
    case Err(e) -> panic("mTLS CA load failed: " + TlsError.message(e))
  }
  return TlsServerConfig(identity = id, minVersion = Tls12, clientCa = Some(value = ca), requireClientCert = true)
}

func greetRouter(): Web.Router {
  var r = Web.create()
  r = Web.addGet(r, "/hello/{name}", HelloHandler())
  r
}

record HelloHandler {
}

impl Web.Handler for HelloHandler {
  func handle(req: in Web.Request): Web.Response {
    val name = match Web.pathParam(req, "name") { case Some(n) -> n; case None -> "world" }
    Web.text(200, "Hello, " + name + "!")
  }
}

// Start `Web.serveTls` on a background task and drive it with the real Lyric
// HTTPS client (`client`, which trusts the fixture cert) in a bounded poll:
// the server binds asynchronously on its task, so the GET is retried until the
// socket accepts, up to a total budget.  The first successful response ends the
// loop and its (status, body) is returned; an exhausted budget returns
// `(0, "")`.
// Run `Web.serveTls` (which blocks forever once bound) — invoked on a
// background `Task.Run` by `serveAndGet`.  A named function (rather than an
// inline closure body) keeps the `taskRun` closure a single call, mirroring
// `tcp_host_tls_tests.l`'s `taskRun({ -> plainEchoServer(...) })` shape.
func runServeTlsBg(r: in Web.Router, port: in Int, tls: in Std.Tls.TlsServerConfig): Unit {
  match Web.serveTls(r, "127.0.0.1", port, tls) {
    case Ok(_) -> ()
    case Err(e) -> panic("serveTls failed to bind: " + Web.ServeTlsError.message(e))
  }
}

func serveAndGet(tls: in Std.Tls.TlsServerConfig, port: in Int, client: in HttpClient): (Int, String) {
  val r = greetRouter()
  val _ = taskRun({ -> runServeTlsBg(r, port, tls) })
  val url = "https://localhost:" + port.toString() + "/hello/Ada"
  var attempt = 0
  var status = 0
  var body = ""
  var done = false
  while attempt < 40 and not done {
    threadSleep(50)
    match await client.get(url) {
      case Ok(resp) -> {
        status = HttpResponse.statusCode(resp)
        body = match await HttpResponse.bodyText(resp) { case Ok(b) -> b; case Err(_) -> "" }
        done = true
      }
      case Err(_) -> {
        attempt = attempt + 1
      }
    }
  }
  return (status, body)
}

test "serveTls terminates real TLS on dotnet and round-trips a request" {
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withCaCertificate(
      HttpClientBuilder.new(),
      match Certificate.fromPem(certPem) {
        case Ok(c) -> c
        case Err(e) -> panic("client CA load failed: " + TlsError.message(e))
      }
    )
  )
  val (status, body) = serveAndGet(fixtureConfig(), 18931, client)
  assertEqualInt(status, 200, "TLS-terminated Web.serveTls returns 200")
  assertEqual(body, "Hello, Ada!", "path param routed over TLS")
}

test "serveTls enforces mTLS: a client presenting a CA-chained cert is accepted" {
  val ca = match Certificate.fromPem(caCertPem) {
    case Ok(c) -> c
    case Err(e) -> panic("client CA load failed: " + TlsError.message(e))
  }
  val clientId = match Identity.fromPem(clientCertPem, clientKeyPem) {
    case Ok(i) -> i
    case Err(e) -> panic("client identity load failed: " + TlsError.message(e))
  }
  val client = HttpClientBuilder.build(
    HttpClientBuilder.withClientIdentity(
      HttpClientBuilder.withExclusiveCaCertificate(HttpClientBuilder.new(), ca),
      clientId
    )
  )
  val (status, body) = serveAndGet(mtlsConfig(), 18932, client)
  assertEqualInt(status, 200, "mTLS client with a CA-chained cert is accepted; 200 returned")
  assertEqual(body, "Hello, Ada!", "mTLS request routed over TLS")
}

test "serveTls rejects a mutual-TLS misconfiguration (requireClientCert without clientCa) with a typed error" {
  val id = match Identity.fromPem(serverCertPem, serverKeyPem) {
    case Ok(i) -> i
    case Err(e) -> panic("server identity load failed: " + TlsError.message(e))
  }
  val badCfg = TlsServerConfig(identity = id, minVersion = Tls12, clientCa = None, requireClientCert = true)
  match Web.serveTls(greetRouter(), "127.0.0.1", 18933, badCfg) {
    case Ok(_) -> panic("expected Err for requireClientCert without clientCa")
    case Err(e) -> match e { case ServerTlsUnsupported(msg) -> assertTrue(msg.contains("requireClientCert") or msg.contains("clientCa"), "message names the mutual-TLS misconfiguration: " + msg) }
  }
}

test "ServeTlsError.message returns the carried message" {
  val e = ServerTlsUnsupported(message = "some reason")
  assertEqual(ServeTlsError.message(e), "some reason", "message accessor")
}

test "WebTls carries required + defaulted fields" {
  val cfg = WebTls(
    certPath = "/etc/tls/cert.pem",
    keyPath = "/etc/tls/key.pem",
    clientCaPath = "",
    requireClientCert = false
  )
  assertEqual(cfg.certPath, "/etc/tls/cert.pem", "certPath")
  assertEqual(cfg.keyPath, "/etc/tls/key.pem", "keyPath")
  assertEqual(cfg.clientCaPath, "", "clientCaPath default")
  assertFalse(cfg.requireClientCert, "requireClientCert default")
}

test "tlsServerConfigFromWebTls loads a valid PEM cert+key into a TlsServerConfig" {
  // Write the fixture PEMs to temp files so WebTls' path-based loader can read
  // them, then round-trip through tlsServerConfigFromWebTls.
  val dir = Env.getVarOrDefault("TMPDIR", "/tmp")
  val certFile = dir + "/lyric_web_tls_cert_18934.pem"
  val keyFile = dir + "/lyric_web_tls_key_18934.pem"
  match writeText(certFile, certPem) {
    case Ok(_) -> ()
    case Err(_) -> panic("write cert fixture failed")
  }
  match writeText(keyFile, keyPem) {
    case Ok(_) -> ()
    case Err(_) -> panic("write key fixture failed")
  }
  val cfg = WebTls(certPath = certFile, keyPath = keyFile, clientCaPath = "", requireClientCert = false)
  match tlsServerConfigFromWebTls(cfg) {
    case Ok(tls) -> assertFalse(tls.requireClientCert, "loaded config carries requireClientCert = false")
    case Err(e) -> panic("expected Ok loading a valid PEM cert+key, got: " + TlsError.message(e))
  }
}

test "tlsServerConfigFromWebTls reports a missing cert file as CertFileNotFound" {
  val cfg = WebTls(
    certPath = "/nonexistent/lyric-web-tls-cert.pem",
    keyPath = "/nonexistent/lyric-web-tls-key.pem",
    clientCaPath = "",
    requireClientCert = false
  )
  match tlsServerConfigFromWebTls(cfg) {
    case Ok(_) -> panic("expected Err for a missing cert file")
    case Err(e) -> match e { case CertFileNotFound(_) -> assertTrue(true, "missing file surfaces as CertFileNotFound"); case PemMalformed(_, _) -> panic("expected CertFileNotFound, got PemMalformed"); case KeyMismatch(_, _) -> panic("expected CertFileNotFound, got KeyMismatch"); case Unsupported(_, _) -> panic("expected CertFileNotFound, got Unsupported") }
  }
}
