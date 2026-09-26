# UI web host: `wss` session socket behind a TLS proxy

`Ui.Host.Web`'s page shell always pointed the browser at a `ws://` session
socket, so a page served over HTTPS (through a TLS-terminating proxy) could
not connect: browsers refuse a plain socket from an HTTPS page. The shell
now derives the socket URL with `sessionSocketUrl`: scheme `wss` when the
proxy sends `X-Forwarded-Proto: https` (first value when several proxies
append to it), `ws` otherwise, and a new `HostConfig.publicWsUrl`
overrides it for a proxy that exposes the socket at a different host or
path. docs/65 §9.5 and the `lyric-ui` README now state that the session id
is a bearer credential that must travel over TLS in production; §10.1
notes that eviction's scan is linear in `maxSessions`. Covered by
`lyric-ui/tests/host_tests.l` ("session socket url follows the page
scheme").
