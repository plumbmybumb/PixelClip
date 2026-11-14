idf_component_register(
    SRCS "power.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES timekeeping health esp_adc esp_pm esp_timer esp_driver_gpio esp_driver_usb_serial_jtag esp_hw_support driver
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
