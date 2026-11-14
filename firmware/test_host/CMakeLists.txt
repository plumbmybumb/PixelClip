# Host-side unit tests for portable firmware code (no ESP-IDF):
#   cmake -S firmware/test_host -B /tmp/pixelclip-test && cmake --build /tmp/pixelclip-test && /tmp/pixelclip-test/test_frame
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
