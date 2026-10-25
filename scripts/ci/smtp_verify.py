#!/usr/bin/env python3
"""Check the two messages lyric-mail's round-trip test sends (#7462).

    smtp_verify.py CAPTURE_DIR

CAPTURE_DIR is the output of smtp_capture_server.py after the
`mail_tests.l` round-trip test ran.  The checks parse each message with the
standard `email` package, so they hold for any provider's choice of MIME
transfer encoding and header folding; they pin what the sender must preserve:
the envelope (Bcc is an envelope recipient only), the address headers and
display names, the decoded subject and body, the multipart structure and the
attachment filename and payload.  Exits 1 and lists every failure.
"""
import email
import email.policy
import os
import sys

failures = []


def expect(cond, what):
    if not cond:
        failures.append(what)


def envelope(path):
    out = {"rcpt": []}
    with open(path, encoding="utf-8") as f:
        for line in f.read().splitlines():
            k, _, v = line.partition("=")
            if k == "rcpt":
                out["rcpt"].append(v)
            else:
                out[k] = v
    return out


def load(d, n):
    with open(os.path.join(d, f"{n}.eml"), "rb") as f:
        return email.message_from_binary_file(f, policy=email.policy.default)


def addrs(header):
    return [(a.display_name, a.addr_spec) for a in header.addresses] if header else []


def main():
    d = sys.argv[1]
    for n in (1, 2):
        if not os.path.exists(os.path.join(d, f"{n}.eml")):
            print(f"FAIL: message {n} was not delivered")
            return 1

    e1 = envelope(os.path.join(d, "1.envelope"))
    m1 = load(d, 1)
    expect(e1.get("mail-from") == "sender@example.com", "envelope sender")
    expect(e1.get("auth") == "ci-user", "authenticated as the configured user")
    expect(
        sorted(e1["rcpt"]) == ["cc@example.com", "hidden@example.com", "to1@example.com", "to2@example.com"],
        f"envelope recipients (to + cc + bcc), got {e1['rcpt']}",
    )
    expect(addrs(m1["From"]) == [("Sender Name", "sender@example.com")], f"From, got {addrs(m1['From'])}")
    expect(
        addrs(m1["To"]) == [("To One", "to1@example.com"), ("", "to2@example.com")],
        f"To, got {addrs(m1['To'])}",
    )
    expect(addrs(m1["Cc"]) == [("", "cc@example.com")], "Cc")
    expect(addrs(m1["Reply-To"]) == [("", "reply@example.com")], "Reply-To")
    expect(m1["Subject"] == "Plain roundtrip café", f"decoded Subject, got {m1['Subject']!r}")
    expect(m1["Bcc"] is None, "no Bcc header")
    expect("hidden@example.com" not in m1.as_string(), "the Bcc address appears nowhere in the message")
    expect(not m1.is_multipart(), "a message without attachments is a single part")
    expect(m1.get_content_type() == "text/plain", f"text/plain body, got {m1.get_content_type()}")
    expect(m1.get_content().replace("\r\n", "\n").strip() == "line one\nline two", "text body round trips")

    e2 = envelope(os.path.join(d, "2.envelope"))
    m2 = load(d, 2)
    expect(e2["rcpt"] == ["to1@example.com"], "second message envelope")
    expect(m2.get_content_type() == "multipart/mixed", f"multipart/mixed, got {m2.get_content_type()}")
    parts = list(m2.iter_parts()) if m2.is_multipart() else []
    expect(len(parts) == 2, f"body part plus one attachment, got {len(parts)} parts")
    if len(parts) == 2:
        body, att = parts
        expect(body.get_content_type() == "text/html", f"HTML body wins over the text body, got {body.get_content_type()}")
        expect(body.get_content().strip() == "<p>html body</p>", "HTML body round trips")
        expect(att.get_filename() == "hello.txt", f"Content-Disposition filename, got {att.get_filename()!r}")
        expect(att.get_content_type() == "text/plain", f"attachment content type, got {att.get_content_type()}")
        expect(att.get_content_disposition() == "attachment", "attachment disposition")
        expect(att.get_payload(decode=True) == b"Hello, attachment!", "attachment bytes round trip")

    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
