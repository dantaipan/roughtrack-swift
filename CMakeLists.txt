cmake_minimum_required(VERSION 3.22)

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")

project(RoughTrackSwift VERSION 0.1.2 LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(cmake/Dependencies.cmake)
include(CTest)

# The C++ half of the app: the engine, and the core the SwiftUI app talks to.
# The app itself is the Xcode project in app/, which links these libraries.
add_subdirectory(engine)
add_subdirectory(core)
add_subdirectory(tools)

if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
