cmake_minimum_required(VERSION 3.16)
project(lyric_rt C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(lyric_rt STATIC
    src/lyric_rt.c
    src/lyric_string.c
    src/lyric_weak.c
    src/lyric_posix.c
    src/lyric_collections.c
    src/lyric_async.c
    src/lyric_fs.c
    src/lyric_process.c
    src/lyric_tls.c
)
target_include_directories(lyric_rt PUBLIC include)
target_compile_options(lyric_rt PRIVATE -Wall -Wextra -Werror)

enable_testing()
add_executable(lyric_rt_test test/lyric_rt_test.c)
# The TLS seam dlopen's OpenSSL at runtime, so it needs libdl (a no-op stub
# on glibc >= 2.34) in addition to pthread; no link-time -lssl/-lcrypto.
target_link_libraries(lyric_rt_test lyric_rt pthread ${CMAKE_DL_LIBS})
add_test(NAME lyric_rt_test COMMAND lyric_rt_test)

add_executable(lyric_tls_test test/lyric_tls_test.c)
target_link_libraries(lyric_tls_test lyric_rt pthread ${CMAKE_DL_LIBS})
add_test(NAME lyric_tls_test COMMAND lyric_tls_test)
