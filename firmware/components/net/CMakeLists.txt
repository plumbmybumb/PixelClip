idf_component_register(
    SRCS "net.c" "http_api.c" "api_ble.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES esp_wifi esp_netif lwip esp_event esp_http_server espressif__mdns json esp_timer app_update
                  storage player core appcfg timekeeping power display ota batlog sched imu reader ble health
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
