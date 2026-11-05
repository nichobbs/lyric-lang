# Every aspect is woven before the check (docs/70 phase 3b S3, D392)

`from`-instances of library templates (C-mode splices, B'-mode specialisations)
are woven before the type check along with the package's own aspects. Templates
are collected from every package's file before any is checked; the spliced
advice is checked in the consuming package, which gains the template's package
and imports. `pipeWeave` becomes `pipeFinishWeave` (format lowering, the await
hoist), the aspect declarations are dropped after the check, and the wrapper
marker is `@__lyric_woven`. lyric-mq and lyric-cache make the values their aspect
bodies name `pub`, and lyric-resilience qualifies four calls. See D392.
