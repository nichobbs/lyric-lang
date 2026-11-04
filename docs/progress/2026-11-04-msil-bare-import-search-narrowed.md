# MSIL's bare-import search is narrowed to a fallback (#8612)

D336.

- `pkgImportAliases` and the async pre-scan's alias candidates are removed;
  an alias-qualified call binds through its site.
- A body specialised from another package's generic binds through that
  package's sites, kept as `CodegenCtx.originCalleeSites` (`<package>|<key>`).
- Defaults (parameters, record fields) mean the declaring package's names:
  same-package callees are qualified from the sites, others resolve at fetch
  in the declaring package's scope (`CodegenCtx.defaultDeclPkg`), which fixes
  restored and stdlib defaults that used to resolve in the consumer's scope
  by luck.
- `findBareImportedFqnMsil` stays as the documented fallback for a call with
  no site: the census (all manifests, stdlib tests, 466 compiler self-tests)
  found aspect-template splices, weaver-synthesised calls and calls in an
  imported generic without a declaring-package site. Next on #8612: have the
  weaver qualify what it splices, then delete it; then the JVM's bare-name
  keys, then native.
