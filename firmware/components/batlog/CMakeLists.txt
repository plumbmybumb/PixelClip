idf_component_register(
    SRCS "batlog.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES storage power timekeeping esp_timer
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
