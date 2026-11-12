# 2026-11-12 - TIR builder: default arguments that are calls (D581)

docs/70 phase 3a, #8613. A defaulted argument that is a call, constructor or other value built from the declaration (`newList()`) now builds when its function is in the same package: the expression is built under the parameter's type and copied with fresh node ids at each call. A default declared in another package is counted as its own kind until package interfaces carry defaults. `tir_build_self_test.l` adds a two-call case and renames the two cases that used a call as their example of an unbuildable default (140 pass).

Wide census: compiler 11357 to 11399 bodies built (I0002 1210 to 1170), ecosystem 2536 to 2556, stdlib tests 1142 to 1145, I0003 0. Defaults left: 62 compiler and 4 ecosystem sites, all declared in another package.
