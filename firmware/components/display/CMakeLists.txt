idf_component_register(
    SRCS "display.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_lcd driver esp_timer
    PRIV_REQUIRES espressif__esp_lcd_sh8601 esp_driver_spi esp_driver_gpio
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
