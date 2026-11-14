# core/ — portable Hair Clip library (.hca decoder + live scenes + board + reader painter + text layout +
# Oracle state machine and sentence reader).
#
# Two modes:
#  * ESP-IDF component: add this directory to EXTRA_COMPONENT_DIRS (component name "core") and
#    REQUIRES core from the firmware component.
#  * Host: cmake -S core -B build/core && cmake --build build/core && ctest --test-dir build/core
#    builds the static library, the test suite and the tools/ CLIs.

if(ESP_PLATFORM)
    idf_component_register(SRCS "src/hca.c"
                                "src/scene.c" "src/scene_grid.c" "src/scene_fire.c" "src/scene_balls.c" "src/scene_words.c" "src/board.c"
                                "src/rsvp_tok.c" "src/rsvp_font.c" "src/rsvp_paint.c"
                                "src/textlay.c"
                                "src/oracle.c" "src/oracle_reader.c" "src/oracle_text.c"
                           INCLUDE_DIRS "include"
                           PRIV_INCLUDE_DIRS "src")
    # The RLE decoder runs for every frame; keep it optimised even in debug (-Og) firmware builds.
    target_compile_options(${COMPONENT_LIB} PRIVATE -O2 -std=gnu11)
    return()
endif()

cmake_minimum_required(VERSION 3.16)
project(hair_core C)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

option(HCA_BUILD_TESTS "Build the host test suite" ON)
option(HCA_BUILD_TOOLS "Build tools/ (hcaenc, hcainfo, hcadec, previews)" ON)
option(HCA_SANITIZE "Build everything with -fsanitize=address,undefined" OFF)

set(HCA_WARN -Wall -Wextra -Werror)
if(HCA_SANITIZE)
    add_compile_options(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g)
    add_link_options(-fsanitize=address,undefined)
endif()

add_library(hca_core STATIC src/hca.c
            src/scene.c src/scene_grid.c src/scene_fire.c src/scene_balls.c src/scene_words.c src/board.c
            src/rsvp_tok.c src/rsvp_font.c src/rsvp_paint.c
            src/textlay.c
            src/oracle.c src/oracle_reader.c src/oracle_text.c)
target_include_directories(hca_core PUBLIC include PRIVATE src)
target_compile_options(hca_core PRIVATE ${HCA_WARN} -O2)

if(HCA_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

if(HCA_BUILD_TOOLS AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../tools/CMakeLists.txt")
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../tools" "${CMAKE_CURRENT_BINARY_DIR}/tools")
endif()
