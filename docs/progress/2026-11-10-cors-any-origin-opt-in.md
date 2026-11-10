# lyric-web: CORS `*` is an explicit opt-in (2026-11-10)

`Web.corsMiddleware` and `Web.corsSettingsError` now refuse `*` as the origin list (#8933). Answering
every site is requested through `Web.corsAnyOriginMiddleware(methods, headers, maxAge)`, or under
`Web.start` with `LYRIC_CONFIG_WEB_CORS_ALLOWANYORIGIN=true` alongside
`LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS=*`. `corsWildcardError` rejects `*` without the opt-in and the opt-in
with an explicit list, so a copied example cannot open the API to every origin silently. Covered by
`dispatch_tests.l` and `cors_guard_tests.l`.
