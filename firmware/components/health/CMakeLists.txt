idf_component_register(
    SRCS "health.c" "health_safe.c" "coredump.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES esp_timer esp_system esp_rom esp_hw_support hal soc nvs_flash log espcoredump esp_partition heap
                  esp_app_format
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
# coredump.c: skip IDF's core dump startup hook when the partition table has no coredump partition
# (it would log an error at every boot of a clip updated over OTA from the old layout).
target_link_libraries(${COMPONENT_LIB} INTERFACE "-Wl,--wrap=esp_core_dump_init")
