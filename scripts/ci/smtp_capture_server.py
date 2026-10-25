#!/usr/bin/env python3
"""Minimal SMTP server that records what it receives, for lyric-mail CI.

    smtp_capture_server.py OUT_DIR [--user U --password P]

Listens on 127.0.0.1 on a free port, writes the port to OUT_DIR/port once it
accepts connections, and for every delivered message writes OUT_DIR/N.eml (the
DATA section, dot-unstuffed) and OUT_DIR/N.envelope (the SMTP envelope and the
authenticated user, one `key=value` per line).  With --user/--password it
requires AUTH PLAIN or AUTH LOGIN with those credentials.  No TLS: the
STARTTLS path is exercised by the JDK/.NET providers' own suites.
"""
import argparse
import base64
import itertools
import os
import socketserver
import sys
import threading

counter = itertools.count(1)
counter_lock = threading.Lock()


class Handler(socketserver.StreamRequestHandler):
    def reply(self, line):
        self.wfile.write((line + "\r\n").encode("ascii"))
        self.wfile.flush()

    def readline(self):
        raw = self.rfile.readline()
        if not raw:
            return None
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if self.server.opts.verbose:
            print("C:", line, file=sys.stderr, flush=True)
        return line

    def check_credentials(self, user, password):
        o = self.server.opts
        return o.user is None or (user == o.user and password == o.password)

    def handle(self):
        o = self.server.opts
        user = None
        mail_from = None
        rcpts = []
        self.reply("220 lyric-ci ESMTP")
        while True:
            line = self.readline()
            if line is None:
                return
            cmd = line.upper()
            if cmd.startswith("EHLO") or cmd.startswith("HELO"):
                if cmd.startswith("EHLO"):
                    self.wfile.write(b"250-lyric-ci\r\n250-8BITMIME\r\n")
                    if o.user is not None:
                        self.wfile.write(b"250-AUTH PLAIN LOGIN\r\n")
                    self.wfile.write(b"250 SIZE 52428800\r\n")
                    self.wfile.flush()
                else:
                    self.reply("250 lyric-ci")
            elif cmd.startswith("AUTH PLAIN"):
                token = line[len("AUTH PLAIN"):].strip()
                if not token:
                    self.reply("334 ")
                    token = self.readline() or ""
                parts = base64.b64decode(token).split(b"\0")
                u, p = parts[-2].decode(), parts[-1].decode()
                if self.check_credentials(u, p):
                    user = u
                    self.reply("235 2.7.0 Authentication successful")
                else:
                    self.reply("535 5.7.8 Authentication failed")
            elif cmd.startswith("AUTH LOGIN"):
                inline = line[len("AUTH LOGIN"):].strip()
                if not inline:
                    self.reply("334 " + base64.b64encode(b"Username:").decode())
                    inline = self.readline() or ""
                u = base64.b64decode(inline).decode()
                self.reply("334 " + base64.b64encode(b"Password:").decode())
                p = base64.b64decode(self.readline() or "").decode()
                if self.check_credentials(u, p):
                    user = u
                    self.reply("235 2.7.0 Authentication successful")
                else:
                    self.reply("535 5.7.8 Authentication failed")
            elif cmd.startswith("MAIL FROM:"):
                if o.user is not None and user is None:
                    self.reply("530 5.7.0 Authentication required")
                    continue
                mail_from = line[len("MAIL FROM:"):].strip().split()[0].strip("<>")
                rcpts = []
                self.reply("250 2.1.0 OK")
            elif cmd.startswith("RCPT TO:"):
                rcpts.append(line[len("RCPT TO:"):].strip().split()[0].strip("<>"))
                self.reply("250 2.1.5 OK")
            elif cmd == "DATA":
                if mail_from is None or not rcpts:
                    self.reply("503 5.5.1 need MAIL and RCPT first")
                    continue
                self.reply("354 End data with <CR><LF>.<CR><LF>")
                body = []
                while True:
                    row = self.readline()
                    if row is None:
                        return
                    if row == ".":
                        break
                    body.append(row[1:] if row.startswith("..") else row)
                with counter_lock:
                    n = next(counter)
                with open(os.path.join(o.out_dir, f"{n}.eml"), "w", encoding="utf-8", newline="") as f:
                    f.write("\r\n".join(body) + "\r\n")
                with open(os.path.join(o.out_dir, f"{n}.envelope"), "w", encoding="utf-8") as f:
                    f.write(f"auth={user or ''}\nmail-from={mail_from}\n")
                    for r in rcpts:
                        f.write(f"rcpt={r}\n")
                self.reply(f"250 2.0.0 OK queued as {n}")
                mail_from, rcpts = None, []
            elif cmd == "RSET":
                mail_from, rcpts = None, []
                self.reply("250 2.0.0 OK")
            elif cmd == "NOOP":
                self.reply("250 2.0.0 OK")
            elif cmd == "QUIT":
                self.reply("221 2.0.0 Bye")
                return
            else:
                self.reply("502 5.5.2 command not recognised")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--user")
    ap.add_argument("--password")
    ap.add_argument("--verbose", action="store_true", help="log client lines to stderr")
    opts = ap.parse_args()
    os.makedirs(opts.out_dir, exist_ok=True)
    server = Server(("127.0.0.1", 0), Handler)
    server.opts = opts
    port_file = os.path.join(opts.out_dir, "port")
    with open(port_file + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.replace(port_file + ".tmp", port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
