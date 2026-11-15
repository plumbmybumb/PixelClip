# Host-side unit tests for portable firmware code:
#   cmake -S firmware/test_host -B /tmp/pixelclip-test && cmake --build /tmp/pixelclip-test && ctest --test-dir /tmp/pixelclip-test
# test_frame, test_safe_start, test_ota_gate and test_press_seq need no ESP-IDF. test_json_depth compiles ESP-IDF's own cJSON source (the parser the firmware
# links) with the firmware's nesting cap, so it needs an ESP-IDF checkout: $IDF_PATH, else ~/esp/esp-idf.
cmake_minimum_required(VERSION 3.16)
project(pixelclip_host_tests C)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra -Werror -fsanitize=address,undefined -g)
add_link_options(-fsanitize=address,undefined)
add_executable(test_frame test_frame.c ../components/ble/pixelclip_frame.c)
target_include_directories(test_frame PRIVATE ../components/ble/include)
enable_testing()
add_test(NAME test_frame COMMAND test_frame)

# Safe start after repeated early crashes (components/health/health_safe.c: pure C).
add_executable(test_safe_start test_safe_start.c ../components/health/health_safe.c)
target_include_directories(test_safe_start PRIVATE ../components/health/include)
add_test(NAME test_safe_start COMMAND test_safe_start)

# The button permission for firmware updates (components/ota/ota_gate.c: pure C).
add_executable(test_ota_gate test_ota_gate.c ../components/ota/ota_gate.c)
target_include_directories(test_ota_gate PRIVATE ../components/ota/include)
add_test(NAME test_ota_gate COMMAND test_ota_gate)

# The hotspot password reset gesture (components/button/press_seq.c: pure C).
add_executable(test_press_seq test_press_seq.c ../components/button/press_seq.c)
target_include_directories(test_press_seq PRIVATE ../components/button/include)
add_test(NAME test_press_seq COMMAND test_press_seq)

# JSON nesting cap (security audits WIFI-3 and PARSE-1): the same cJSON.c and the same CJSON_NESTING_LIMIT as the firmware
# build (../json_limit.cmake, applied to the `json` component in ../CMakeLists.txt).
include(${CMAKE_CURRENT_LIST_DIR}/../json_limit.cmake)
set(PIXELCLIP_IDF_PATH "$ENV{IDF_PATH}")
if(NOT PIXELCLIP_IDF_PATH)
    set(PIXELCLIP_IDF_PATH "$ENV{HOME}/esp/esp-idf")
endif()
set(CJSON_DIR "${PIXELCLIP_IDF_PATH}/components/json/cJSON")
if(EXISTS "${CJSON_DIR}/cJSON.c")
    add_library(idf_cjson STATIC "${CJSON_DIR}/cJSON.c")
    target_include_directories(idf_cjson PUBLIC "${CJSON_DIR}")
    target_compile_definitions(idf_cjson PUBLIC CJSON_NESTING_LIMIT=${PIXELCLIP_JSON_NESTING_LIMIT})
    target_compile_options(idf_cjson PRIVATE -w)   # third-party source: not held to -Wextra -Werror
    add_executable(test_json_depth test_json_depth.c)
    target_link_libraries(test_json_depth PRIVATE idf_cjson m)
    add_test(NAME test_json_depth COMMAND test_json_depth)
else()
    message(WARNING "test_json_depth skipped: no ESP-IDF cJSON at ${CJSON_DIR} (set IDF_PATH)")
endif()
