idf_component_register(
    SRCS "ota.c" "ota_gate.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES app_update mbedtls esp_timer esp_system freertos
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
