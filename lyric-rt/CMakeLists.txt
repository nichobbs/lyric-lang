cmake_minimum_required(VERSION 3.16)
project(lyric_rt C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(WIN32)
    # docs/67 G9: the Win32 twins of lyric_posix.c, lyric_fs.c and
    # lyric_process.c; sockets and TLS use lyric_net_unsupported.c until
    # their port lands (#8434).
    set(LYRIC_RT_PLATFORM_SRCS
        src/lyric_win32.c
        src/lyric_fs_win32.c
        src/lyric_process_win32.c
        src/lyric_net_unsupported.c
    )
else()
    set(LYRIC_RT_PLATFORM_SRCS
        src/lyric_posix.c
        src/lyric_fs.c
        src/lyric_process.c
        src/lyric_tls.c
    )
endif()

add_library(lyric_rt STATIC
    src/lyric_rt.c
    src/lyric_string.c
    src/lyric_weak.c
    src/lyric_collections.c
    src/lyric_async.c
    src/lyric_parallel.c
    ${LYRIC_RT_PLATFORM_SRCS}
)
target_include_directories(lyric_rt PUBLIC include)
target_compile_options(lyric_rt PRIVATE -Wall -Wextra -Werror)

enable_testing()
add_executable(lyric_rt_test test/lyric_rt_test.c)
add_executable(lyric_parallel_test test/lyric_parallel_test.c)
if(WIN32)
    target_compile_definitions(lyric_rt PRIVATE _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS)
    target_link_libraries(lyric_rt PUBLIC bcrypt shell32)
    target_link_libraries(lyric_rt_test lyric_rt)
    target_link_libraries(lyric_parallel_test lyric_rt)
    add_executable(lyric_win32_test test/lyric_win32_test.c)
    target_link_libraries(lyric_win32_test lyric_rt)
    add_test(NAME lyric_win32_test COMMAND lyric_win32_test)
    add_executable(lyric_process_win32_test test/lyric_process_win32_test.c)
    target_link_libraries(lyric_process_win32_test lyric_rt)
    add_test(NAME lyric_process_win32_test COMMAND lyric_process_win32_test)
else()
    # The TLS seam dlopen's OpenSSL at runtime, so it needs libdl (a no-op stub
    # on glibc >= 2.34) in addition to pthread; no link-time -lssl/-lcrypto.
    target_link_libraries(lyric_rt_test lyric_rt pthread ${CMAKE_DL_LIBS})
    target_link_libraries(lyric_parallel_test lyric_rt pthread)
    add_executable(lyric_tls_test test/lyric_tls_test.c)
    target_link_libraries(lyric_tls_test lyric_rt pthread ${CMAKE_DL_LIBS})
    add_test(NAME lyric_tls_test COMMAND lyric_tls_test)
endif()
add_test(NAME lyric_rt_test COMMAND lyric_rt_test)
add_test(NAME lyric_parallel_test COMMAND lyric_parallel_test)
