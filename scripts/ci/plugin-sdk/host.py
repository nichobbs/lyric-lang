#!/usr/bin/env python3
"""A scripted plugin host speaking the D207 plugin protocol, version 1.

Drives one plugin built against a generated SDK through the manifest probe,
the `plugin/hello` handshake (including a refused one), point calls with
every boundary type of scripts/ci/plugin-sdk/api/demo_api.l, reverse
capability calls (granted, denied, an application error, two in flight at
once answered out of order), the boundary error codes and shutdown.

Usage: host.py <expected plugin id> <command> [args...]
Exits 0 when every check passes and prints the first failure otherwise.
"""
import json
import queue
import subprocess
import sys
import threading

TIMEOUT = 60

POINT = "Demo.Api.Greeter"
FILES = "Demo.Api.Files"
NOTIFY = "Demo.Api.Notify"
METHODS = ["greet", "area", "open", "echo", "readVia"]
DENIED, NOT_GRANTED, UNSUPPORTED, PROTOCOL = -32040, -32041, -32043, -32046


class Failure(Exception):
    pass


def check(cond, what):
    if not cond:
        raise Failure(what)


def check_eq(actual, expected, what):
    if actual != expected:
        raise Failure(what + ":\n  expected " + json.dumps(expected) + "\n  actual   " + json.dumps(actual))


class Plugin:
    def __init__(self, command):
        self.proc = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8"
        )
        self.incoming = queue.Queue()
        self.next_id = 100
        self.stderr = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if line:
                self.incoming.put(line)
        self.incoming.put(None)

    def _drain_stderr(self):
        for line in self.proc.stderr:
            self.stderr.append(line)

    def send(self, msg):
        self.proc.stdin.write(json.dumps(msg, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def receive(self):
        try:
            line = self.incoming.get(timeout=TIMEOUT)
        except queue.Empty:
            raise Failure("the plugin sent nothing for " + str(TIMEOUT) + "s")
        if line is None:
            raise Failure("the plugin closed stdout; stderr:\n" + "".join(self.stderr))
        try:
            msg = json.loads(line)
        except ValueError as e:
            raise Failure("the plugin wrote a line that is not JSON (" + str(e) + "): " + line)
        check_eq(msg.get("jsonrpc"), "2.0", "every message carries jsonrpc 2.0")
        return msg

    def request(self, method, params, on_capability=None):
        """Sends a request and returns its response, answering capability calls on the way."""
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self.wait(rid, on_capability)

    def wait(self, rid, on_capability=None):
        while True:
            msg = self.receive()
            if "method" in msg:
                check(on_capability is not None, "unexpected request from the plugin: " + json.dumps(msg))
                on_capability(self, msg)
                continue
            check_eq(msg.get("id"), rid, "the response id")
            return msg

    def shutdown(self):
        self.send({"jsonrpc": "2.0", "method": "plugin/shutdown"})
        self.proc.stdin.close()
        try:
            code = self.proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            raise Failure("the plugin did not exit after plugin/shutdown")
        check_eq(code, 0, "the plugin's exit code after shutdown")


def result_of(resp, what):
    check("error" not in resp, what + " failed: " + json.dumps(resp.get("error")))
    return resp["result"]


def error_code(resp, code, what):
    check("error" in resp, what + " should fail with " + str(code) + ", got " + json.dumps(resp))
    check_eq(resp["error"]["code"], code, what + ": the error code")
    check(isinstance(resp["error"].get("message"), str), what + ": the error message is a string")
    return resp["error"]


def files_host(plugin, msg):
    """The host's Files capability: grants roots ["/w"]."""
    check_eq(msg["method"], "cap/" + FILES + "/readFile", "the capability method")
    path = msg["params"]["path"]
    if not path.startswith("/w/"):
        plugin.send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": DENIED, "message": path + " is outside the granted roots"}})
    elif path == "/w/missing":
        plugin.send({"jsonrpc": "2.0", "id": msg["id"], "result": {"err": {"case": "Failed", "detail": "no such file"}}})
    else:
        plugin.send({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": "contents of " + path}})


def probe(command, expected_id):
    run = subprocess.run(command + ["--lyric-plugin-manifest"], capture_output=True, text=True, timeout=TIMEOUT, stdin=subprocess.DEVNULL)
    check_eq(run.returncode, 0, "the manifest probe's exit code (stderr: " + run.stderr.strip() + ")")
    manifest = json.loads(run.stdout)
    check_eq(
        manifest,
        {
            "schema": 1,
            "id": expected_id,
            "version": "1.0.0",
            "publisher": "lyric-e2e",
            "points": [{"point": POINT, "version": "1.2", "contributions": {"commands": ["greet"], "priority": 7}}],
            "capabilities": {
                "required": [{"name": FILES, "grant": {"roots": ["${workspace}"]}}],
                "optional": [{"name": NOTIFY, "grant": None}],
            },
        },
        "the probed manifest",
    )


GREETING = {
    "text": "hello ann",
    "count": 3,
    "big": 9007199254740993,
    "huge": 18446744073709551615,
    "ratio": 0.5,
    "initial": "a",
    "tags": ["a", "b"],
    "mood": "Happy",
    "note": None,
    "data": "AAH/",
    "scores": {"min": -9223372036854775808},
    "pair": [3, "ann"],
    "extra": {"k": [1, 2.5, "s", None, True]},
    "shapes": [{"case": "Circle", "radius": 1.5}, {"case": "Rect", "w": 2, "h": 3}, {"case": "Empty"}],
}


def same_numbers(a, b):
    """Structural equality where 2 and 2.0 are the same JSON number."""
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same_numbers(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same_numbers(x, y) for x, y in zip(a, b))
    return a == b


def session(command, expected_id):
    # A required capability that is not granted: the handshake is refused.
    p = Plugin(command)
    err = error_code(p.request("plugin/hello", {"protocol": 1, "points": {POINT: "1.2"}, "grants": []}), NOT_GRANTED, "hello without Files")
    check_eq((err.get("data") or {}).get("capability"), FILES, "the refused capability")
    p.shutdown()

    p = Plugin(command)
    error_code(p.request(POINT + "/greet", {"name": "x", "times": 1}), PROTOCOL, "a call before the handshake")
    hello = result_of(
        p.request("plugin/hello", {"protocol": 1, "points": {POINT: "1.2"}, "grants": [{"capability": FILES, "grant": {"roots": ["/w"]}}]}),
        "plugin/hello",
    )
    check_eq(hello, {"protocol": 1, "id": expected_id, "points": {POINT: {"version": "1.2", "methods": METHODS}}}, "the handshake answer")
    error_code(p.request("plugin/hello", {"protocol": 1, "points": {}, "grants": []}), PROTOCOL, "a second hello")

    greeting = result_of(p.request(POINT + "/greet", {"name": "ann", "times": 3}), "greet")
    check("ok" in greeting, "greet should succeed: " + json.dumps(greeting))
    check(same_numbers(greeting["ok"], GREETING), "greet's Greeting:\n  expected " + json.dumps(GREETING) + "\n  actual   " + json.dumps(greeting["ok"]))
    check_eq(greeting["ok"]["big"], 9007199254740993, "a Long above 2^53, exactly")
    check_eq(greeting["ok"]["huge"], 18446744073709551615, "the largest ULong, exactly")
    check_eq(list(greeting["ok"].keys()), list(GREETING.keys()), "record members in declaration order")

    check_eq(result_of(p.request(POINT + "/greet", {"name": "", "times": 1}), "greet('')"), {"err": {"case": "BadName", "name": ""}}, "an application error")
    area = result_of(p.request(POINT + "/area", {"s": {"case": "Circle", "radius": 2}}), "area")
    check(same_numbers(area, {"ok": 12}), "area of a circle: " + json.dumps(area))
    check_eq(
        result_of(p.request(POINT + "/open", {"doc": 9007199254740995, "counts": {"a": 1, "b": 2}}), "open"),
        {"ok": [9007199254740995, 9007199254740998]},
        "handles and a map",
    )

    sent = dict(GREETING)
    sent["huge"] = 18446744073709551614
    sent["note"] = "a note"
    sent["unknown member"] = {"ignored": True}
    del sent["shapes"]
    expected = dict(sent)
    del expected["unknown member"]
    expected["shapes"] = []
    echoed = result_of(p.request(POINT + "/echo", {"g": sent}), "echo")
    check(same_numbers(echoed, {"ok": expected}), "echo with a defaulted field:\n  expected " + json.dumps({"ok": expected}) + "\n  actual   " + json.dumps(echoed))

    error_code(p.request(POINT + "/greet", {"name": "ann", "times": "three"}), PROTOCOL, "a wrongly typed parameter")
    error_code(p.request(POINT + "/greet", {"name": "ann"}), PROTOCOL, "a missing parameter")
    error_code(p.request(POINT + "/echo", {"g": dict(GREETING, mood="Grumpy")}), PROTOCOL, "an unknown enum case")
    error_code(p.request(POINT + "/area", {"s": {"case": "Hexagon"}}), PROTOCOL, "an unknown union case")
    error_code(p.request(POINT + "/greet", {"name": "ann", "times": 2147483648}), PROTOCOL, "an Int out of range")
    error_code(p.request(POINT + "/nope", {}), UNSUPPORTED, "an unknown method")
    error_code(p.request("Other.Point/x", {}), UNSUPPORTED, "an unknown point")

    check_eq(
        result_of(p.request(POINT + "/readVia", {"path": "/w/a.txt"}, files_host), "readVia"),
        {"ok": "contents of /w/a.txt (root /w)"},
        "a granted capability call",
    )
    check_eq(
        result_of(p.request(POINT + "/readVia", {"path": "/etc/passwd"}, files_host), "readVia denied"),
        {"err": {"case": "Failed", "detail": "boundary: Denied"}},
        "a denied capability call",
    )
    check_eq(
        result_of(p.request(POINT + "/readVia", {"path": "/w/missing"}, files_host), "readVia missing"),
        {"err": {"case": "Failed", "detail": "no such file"}},
        "a capability's application error",
    )

    # Two point calls in flight; their capability calls are answered in reverse order.
    p.send({"jsonrpc": "2.0", "id": 900, "method": POINT + "/readVia", "params": {"path": "/w/one"}})
    p.send({"jsonrpc": "2.0", "id": 901, "method": POINT + "/readVia", "params": {"path": "/w/two"}})
    caps, answers = [], {}
    while len(caps) < 2:
        msg = p.receive()
        check("method" in msg, "expected two capability calls first, got " + json.dumps(msg))
        caps.append(msg)
    for msg in reversed(caps):
        files_host(p, msg)
    while len(answers) < 2:
        msg = p.receive()
        answers[msg["id"]] = msg
    check_eq(result_of(answers[900], "first concurrent call"), {"ok": "contents of /w/one (root /w)"}, "the first concurrent call")
    check_eq(result_of(answers[901], "second concurrent call"), {"ok": "contents of /w/two (root /w)"}, "the second concurrent call")

    p.send({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 1}})
    p.shutdown()


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    expected_id, command = sys.argv[1], sys.argv[2:]
    try:
        probe(command, expected_id)
        session(command, expected_id)
    except Failure as e:
        print("FAIL (" + expected_id + "): " + str(e), file=sys.stderr)
        return 1
    print("ok: " + expected_id + " passed the protocol checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
