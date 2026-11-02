cmake_minimum_required(VERSION 3.22.1)
project(voicejni C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# whisper.cpp source is cloned here by the GitHub build (see .github/workflows/build.yml).
set(WHISPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp)
if (NOT EXISTS ${WHISPER_DIR}/CMakeLists.txt)
    message(FATAL_ERROR "whisper.cpp not found. Run: git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp android/app/src/main/cpp/whisper.cpp")
endif ()

set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE            OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP            OFF CACHE BOOL "" FORCE)

add_subdirectory(${WHISPER_DIR} whisper-build)

add_library(voicejni SHARED whisper_jni.cpp)
target_link_libraries(voicejni PRIVATE whisper log android)

if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(voicejni PRIVATE -O3)
    target_link_options(voicejni PRIVATE -Wl,--gc-sections)
endif ()
