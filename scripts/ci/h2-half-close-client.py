#!/usr/bin/env python3
"""Raw HTTP/2 client that half-closes after its request (#8683).

    h2-half-close-client.py <base-url> <path> <expected-body>

Negotiates h2 over TLS (certificate checks off: the fixture is self-signed),
sends one GET, shuts down only its write side, and then reads the connection
until the server ends the stream. Exits 0 and prints the elapsed time when the
full body arrives, non-zero with the reason otherwise. Needs no h2 library: the
request uses HPACK's static table and literals only.
"""
import socket
import ssl
import struct
import sys
import time
from urllib.parse import urlsplit

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
DATA, HEADERS, RST_STREAM, SETTINGS, GOAWAY = 0x0, 0x1, 0x3, 0x4, 0x7
END_STREAM, END_HEADERS, ACK = 0x1, 0x4, 0x1


def frame(kind, flags, stream, payload=b""):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload


def literal(name_index, value):
    # Literal header field with incremental indexing, indexed name.
    v = value.encode()
    return bytes([0x40 | name_index, len(v)]) + v


def request_block(authority, path):
    return b"\x82\x87" + literal(1, authority) + literal(4, path)


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return buf


def main():
    base, path, expected = sys.argv[1], sys.argv[2], sys.argv[3]
    url = urlsplit(base)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["h2"])
    raw = socket.create_connection((url.hostname, url.port), timeout=20)
    sock = ctx.wrap_socket(raw, server_hostname=url.hostname)
    if sock.selected_alpn_protocol() != "h2":
        print("h2 was not negotiated")
        return 2
    start = time.time()
    sock.sendall(
        PREFACE
        + frame(SETTINGS, 0, 0)
        + frame(HEADERS, END_HEADERS | END_STREAM, 1, request_block("%s:%d" % (url.hostname, url.port), path))
    )
    # FIN without a TLS close_notify: the server reads end-of-input while its
    # handler is still running.
    raw_shutdown = socket.socket.shutdown
    raw_shutdown(sock, socket.SHUT_WR)
    body, done = b"", False
    try:
        while not done:
            header = read_exact(sock, 9)
            length = int.from_bytes(header[0:3], "big")
            kind, flags = header[3], header[4]
            stream = int.from_bytes(header[5:9], "big") & 0x7FFFFFFF
            payload = read_exact(sock, length) if length else b""
            if kind == DATA and stream == 1:
                body += payload
            if kind == RST_STREAM and stream == 1:
                print("stream reset by the server (error %d)" % int.from_bytes(payload[:4], "big"))
                return 3
            if kind in (DATA, HEADERS) and stream == 1 and flags & END_STREAM:
                done = True
    except (EOFError, ssl.SSLError, OSError) as e:
        print("connection ended before the response completed: %s" % e)
        return 4
    if body.decode() != expected:
        print("unexpected body %r" % body)
        return 5
    print("%dms" % int((time.time() - start) * 1000))
    return 0


sys.exit(main())
