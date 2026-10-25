# 2026-10-25 - lyric-web / lyric-grpc ranged guard config

D249, #7247, #7249.

The rate-limit and circuit-breaker aspects of lyric-web and lyric-grpc and
the `GrpcServer` config block now use range-typed config fields, so a zero
or negative limit, threshold or cooldown is a build error (G0010) and a bad
port or idle timeout exits 78 at startup. The runtime-panic tests for a zero
threshold/cooldown were replaced by a weaver test of the same config shapes.
