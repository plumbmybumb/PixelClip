idf_component_register(
    SRCS "app_main.c" "bench.c"
    INCLUDE_DIRS "."
    REQUIRES nvs_flash mbedtls core esp_event esp_timer esp_system esp_app_format display ui storage appcfg timekeeping power button player net ota batlog sched imu reader ble health esp_pm esp_driver_usb_serial_jtag
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
