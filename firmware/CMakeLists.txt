# PixelClip firmware — ESP-IDF v5.5 project.
cmake_minimum_required(VERSION 3.16)

# The portable core library (hca decoder, renderers, text layout) lives in ../core and registers itself
# as an ESP-IDF component named `core` when ESP_PLATFORM is set.
set(EXTRA_COMPONENT_DIRS ${CMAKE_CURRENT_LIST_DIR}/../core)

set(PROJECT_VER "0.1.0")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(pixelclip)

# Cap the nesting depth cJSON accepts, for every user of ESP-IDF's `json` component (json_limit.cmake).
# PUBLIC: the components that include cJSON.h see the same value, so net/http_api.c can assert it at
# compile time.
include(${CMAKE_CURRENT_LIST_DIR}/json_limit.cmake)
idf_component_get_property(json_lib json COMPONENT_LIB)
target_compile_definitions(${json_lib} PUBLIC CJSON_NESTING_LIMIT=${PIXELCLIP_JSON_NESTING_LIMIT})
