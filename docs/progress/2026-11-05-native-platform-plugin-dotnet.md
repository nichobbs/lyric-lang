# Native platforms: plugin runs with dotnet sides on macOS arm64 and Linux arm64 (#8563, #8419)

- `scripts/ci/native-plugin-e2e.sh` runs every plugin pair with a native side: a native host with native and
  dotnet plugin processes (`plugin-e2e.sh`), protocol sessions native/native, native/dotnet and dotnet/native
  (`plugin-protocol-e2e.sh`), the trusted in-process native plugin (`plugin-trusted-e2e.sh`), and lyric-ui plugin
  widgets with native and dotnet hosts (`ui-widget-plugins-e2e.sh`). Every run happens even when one fails, with a
  summary at the end. The Linux x86-64 lane (`native-backend-self-tests.sh`) and both `native-platforms.yml` jobs
  call it, replacing the single `plugin-e2e.sh native native` step on the new hosts.
- No extra provisioning: the NativeAOT-linked `lyric` on those jobs is the whole compiler, so it builds the dotnet
  payloads and hosts itself, and the jobs already install the .NET SDK (the compiler-hosted suites there run through
  `lyric test`'s dotnet target).
- `macos-graphics-e2e.sh`: the pinned WenQuanYi Zen Hei package falls back to the Debian pool when
  snapshot.debian.org fails (the package SHA-256 pins the bytes either way), notes the `data.tar.xz` coupling, and a
  failed download now stops the script instead of being masked by `export`.
- Verified on x86-64 Linux: the font fetch with a failing first mirror, and with every mirror failing. The new plugin
  runs on macOS and Linux arm64 are confirmed by the `Native platforms` workflow run on this PR.
