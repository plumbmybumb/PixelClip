idf_component_register(
    SRCS "appcfg.c"
    INCLUDE_DIRS "include"
    REQUIRES json
    PRIV_REQUIRES storage timekeeping
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
