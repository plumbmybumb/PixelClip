# Hair Clip firmware — ESP-IDF v5.5 project.
cmake_minimum_required(VERSION 3.16)

# The portable core library (hca decoder, renderers, text layout) lives in ../core and registers itself
# as an ESP-IDF component named `core` when ESP_PLATFORM is set.
set(EXTRA_COMPONENT_DIRS ${CMAKE_CURRENT_LIST_DIR}/../core)

set(PROJECT_VER "0.1.0")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(pixelclip)
