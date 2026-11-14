idf_component_register(
    SRCS "player.c" "playlist.c" "orient.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common json appcfg sched core
    PRIV_REQUIRES display ui storage timekeeping power esp_timer esp_hw_support imu reader health nvs_flash
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)

# Live scenes (PROTOCOL §4 `scene` items, §5b) need the engine in ../core (another work stream).
# Enable them only when core/ actually compiles scene.c into the `core` component; otherwise scene
# items keep being rejected with 422 unknown_scene and GET /scenes stays 404.
set(_core_dir "${CMAKE_CURRENT_LIST_DIR}/../../../core")
set(_have_scenes 0)
if(EXISTS "${_core_dir}/src/scene.c" AND EXISTS "${_core_dir}/include/scene.h")
    file(READ "${_core_dir}/CMakeLists.txt" _core_cmake)
    string(FIND "${_core_cmake}" "src/scene.c" _pos)
    if(NOT _pos EQUAL -1)
        set(_have_scenes 1)
    endif()
endif()
# PUBLIC: net (GET /scenes, playlist error codes) sees the same value through playlist.h.
target_compile_definitions(${COMPONENT_LIB} PUBLIC PIXELCLIP_HAVE_SCENES=${_have_scenes})
message(STATUS "player: live scenes ${_have_scenes}")
