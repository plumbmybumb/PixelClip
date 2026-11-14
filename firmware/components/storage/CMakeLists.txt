idf_component_register(
    SRCS "storage.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common
    PRIV_REQUIRES joltwallet__littlefs mbedtls core vfs
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
