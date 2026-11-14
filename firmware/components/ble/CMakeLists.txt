idf_component_register(
    SRCS "pixelclip_ble.c" "pixelclip_frame.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES bt esp_timer freertos heap health power
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
