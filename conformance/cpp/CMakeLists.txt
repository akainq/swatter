cmake_minimum_required(VERSION 3.16)
project(swatter_conformance_cpp CXX)

set(CMAKE_CXX_STANDARD 17)

include(FetchContent)
# официальный C++ SDK Sentry (crashpad-транспорт отключаем: для conformance
# нужен только HTTP-транспорт события, не minidump-загрузчик)
set(SENTRY_BACKEND none CACHE STRING "" FORCE)
set(SENTRY_TRANSPORT curl CACHE STRING "" FORCE)
FetchContent_Declare(
  sentry
  GIT_REPOSITORY https://github.com/getsentry/sentry-native.git
  GIT_TAG 0.7.17
)
FetchContent_MakeAvailable(sentry)

add_executable(send_error send_error.cpp)
target_link_libraries(send_error PRIVATE sentry::sentry)
