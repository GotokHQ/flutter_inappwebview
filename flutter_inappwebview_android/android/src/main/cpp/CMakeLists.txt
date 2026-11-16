cmake_minimum_required(VERSION 3.18.1)
project(iaw_fast_scroll LANGUAGES C)

# Dart's dynamically linked embedding API (BSD-3-Clause, copied verbatim from
# the Dart SDK's include/ directory). It lets native code enter the isolate
# before invoking a Dart callback.
set(DART_SDK_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dart-sdk/include")

add_library(iaw_fast_scroll SHARED
  iaw_fast_scroll.c
  "${DART_SDK_INCLUDE}/dart_api_dl.c"
)

target_include_directories(iaw_fast_scroll PRIVATE "${DART_SDK_INCLUDE}")

# Keep the Dart_*_DL symbols private to this library so they cannot collide
# with another plugin that also embeds dart_api_dl.c.
target_compile_options(iaw_fast_scroll PRIVATE -fvisibility=hidden)

# Ensure 16 KB ELF segment alignment for Android 15+ / Google Play compliance.
target_link_options(iaw_fast_scroll PRIVATE "-Wl,-z,max-page-size=16384")
