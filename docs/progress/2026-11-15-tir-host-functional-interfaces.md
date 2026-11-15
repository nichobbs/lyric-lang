# 2026-11-15 - TIR builder: function values for host functional interfaces, records for extern interfaces (D470)

docs/70 §6.2, #8613. `Thread.new({ -> ... })` and a Lyric record that `impl`s an extern interface passed as that interface now take `CvBoxToHost`. Over `http_server_jvm_tests`, `http_unix_socket_jvm_tests`, `task_ambient_jvm_tests` and `regex_jvm_deadline_self_test` the extern kinds are now 0 (D466's baseline was 16 "host metadata cannot resolve" and 9 "no host overload fits"; D468 took them to 0 and 6), I0003 stays 0, and 1343 of 1561 bodies build.
