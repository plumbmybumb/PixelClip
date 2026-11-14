idf_component_register(
    SRCS "reader_store.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_common core storage
    PRIV_REQUIRES json mbedtls vfs
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
