cmake_minimum_required(VERSION 3.16)
project(lyric_rt C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(WIN32)
    # Native programs link the static C runtime (clang's default for
    # x86_64-pc-windows-msvc, so they need no Visual C++ redistributable);
    # the runtime and its tests must use the same one.  lyric_rt_md below is
    # the DLL-runtime build an AddressSanitizer program links.
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
endif()

if(WIN32)
    # docs/67 G9: the Win32 twins of lyric_posix.c, lyric_fs.c,
    # lyric_process.c and lyric_tls.c (Winsock and Schannel).
    set(LYRIC_RT_PLATFORM_SRCS
        src/lyric_win32.c
        src/lyric_fs_win32.c
        src/lyric_process_win32.c
        src/lyric_sock_win32.c
        src/lyric_tls_win32.c
        src/lyric_wasmhost_unsupported.c
    )
else()
    set(LYRIC_RT_PLATFORM_SRCS
        src/lyric_posix.c
        src/lyric_fs.c
        src/lyric_process.c
        src/lyric_tls.c
        src/lyric_wasmhost.c
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
# lyric_wasmhost.c compiles against the vendored wasmtime C API headers; it
# loads libwasmtime at run time, so nothing links against it.
target_include_directories(lyric_rt SYSTEM PRIVATE third_party/wasmtime/include)
target_compile_options(lyric_rt PRIVATE -Wall -Wextra -Werror)

if(NOT WIN32)
    # The shared shim for dotnet and JVM plugin hosts (docs/69 §9.3).
    add_library(lyric_wasmhost SHARED src/lyric_wasmhost.c)
    target_include_directories(lyric_wasmhost PRIVATE include)
    target_include_directories(lyric_wasmhost SYSTEM PRIVATE third_party/wasmtime/include)
    target_compile_options(lyric_wasmhost PRIVATE -Wall -Wextra -Werror)
    set_target_properties(lyric_wasmhost PROPERTIES C_VISIBILITY_PRESET hidden)
    target_link_libraries(lyric_wasmhost PRIVATE pthread ${CMAKE_DL_LIBS})
endif()

if(WIN32)
    add_library(lyric_rt_md STATIC
        src/lyric_rt.c
        src/lyric_string.c
        src/lyric_weak.c
        src/lyric_collections.c
        src/lyric_async.c
        src/lyric_parallel.c
        ${LYRIC_RT_PLATFORM_SRCS}
    )
    set_property(TARGET lyric_rt_md PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
    target_include_directories(lyric_rt_md PUBLIC include)
    target_compile_options(lyric_rt_md PRIVATE -Wall -Wextra -Werror)
    target_compile_definitions(lyric_rt_md PRIVATE _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS)
    if(CMAKE_C_COMPILER_FRONTEND_VARIANT STREQUAL "GNU")
        # The clang driver (not clang-cl) takes the runtime choice as a flag,
        # which CMake versions before 3.27 do not pass for it.
        target_compile_options(lyric_rt_md PRIVATE -fms-runtime-lib=dll)
    endif()
endif()

enable_testing()
add_executable(lyric_rt_test test/lyric_rt_test.c)
add_executable(lyric_parallel_test test/lyric_parallel_test.c)
if(WIN32)
    target_compile_definitions(lyric_rt PRIVATE _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS)
    target_link_libraries(lyric_rt PUBLIC bcrypt shell32 advapi32 ws2_32 secur32 crypt32 ncrypt)
    target_link_libraries(lyric_rt_test lyric_rt)
    target_link_libraries(lyric_parallel_test lyric_rt)
    add_executable(lyric_win32_test test/lyric_win32_test.c)
    target_link_libraries(lyric_win32_test lyric_rt)
    add_test(NAME lyric_win32_test COMMAND lyric_win32_test)
    add_executable(lyric_process_win32_test test/lyric_process_win32_test.c)
    target_link_libraries(lyric_process_win32_test lyric_rt)
    add_test(NAME lyric_process_win32_test COMMAND lyric_process_win32_test)
    add_executable(lyric_tls_test test/lyric_tls_test.c)
    target_link_libraries(lyric_tls_test lyric_rt)
    add_test(NAME lyric_tls_test COMMAND lyric_tls_test)
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
