"""SPIKE (docs/73 S0 spike b), not shipped: N concurrent TLS clients against tls_echo_server.l.

Every client connects, completes the handshake, then in two rounds sends a line and waits for the echo
with a pause in between, so all N server-side reads are parked at the same moment. Prints
`PINNING-CLIENT: served=<n> of <N>` and exits non-zero unless all N were served in time.
"""
import socket, ssl, sys, threading, time

port = int(sys.argv[1]); n = int(sys.argv[2]); hold = float(sys.argv[3])
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
served = 0; lock = threading.Lock()

def one(i):
    global served
    try:
        raw = socket.create_connection(("127.0.0.1", port), timeout=15)
        s = ctx.wrap_socket(raw); s.settimeout(15)
        for rnd in range(2):
            s.sendall(("c%d r%d\n" % (i, rnd)).encode())
            want = len(("c%d r%d\n" % (i, rnd)))
            got = b""
            while len(got) < want:
                d = s.recv(4096)
                if not d:
                    return
                got += d
            time.sleep(hold)
        s.close()
        with lock:
            served += 1
    except Exception as e:
        print("client %d failed: %r" % (i, e))

ts = [threading.Thread(target=one, args=(i,)) for i in range(n)]
[t.start() for t in ts]; [t.join() for t in ts]
print("PINNING-CLIENT: served=%d of %d" % (served, n))
sys.exit(0 if served == n else 1)
