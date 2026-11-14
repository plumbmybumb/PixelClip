idf_component_register(
    SRCS "timekeeping.c" "timekeeping_rule.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES nvs_flash esp_system esp_timer esp_rom soc
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
