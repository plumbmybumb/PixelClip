idf_component_register(
    SRCS "sched.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES json storage
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
