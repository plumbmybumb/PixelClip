# Optional boot splash: firmware/main/assets/splash.hca is embedded in the app image when it exists
# at configure time (run `idf.py reconfigure` after adding or removing it). Capped at 400 KB so the
# OTA slots keep >= 25 % headroom; a larger file is left out (and the boot shows no splash).
# The splash belongs to the project being built (PROJECT_DIR/main/assets), not to this component's own tree, so
# another project reusing the component does not embed this firmware's splash. For this firmware PROJECT_DIR is
# firmware/.
idf_build_get_property(_project_dir PROJECT_DIR)
set(_splash "${_project_dir}/main/assets/splash.hca")
set(_splash_embed "")
set(_have_splash 0)
if(EXISTS "${_splash}")
    file(SIZE "${_splash}" _splash_size)
    if(_splash_size GREATER 409600)
        message(STATUS "ui: main/assets/splash.hca is ${_splash_size} B > 400 KB cap: NOT embedded")
    else()
        set(_splash_embed "${_splash}")
        set(_have_splash 1)
        message(STATUS "ui: embedding main/assets/splash.hca (${_splash_size} B)")
    endif()
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_splash}")
endif()

idf_component_register(
    SRCS "ui.c" "font5x7.c"
    INCLUDE_DIRS "include"
    REQUIRES display
    PRIV_REQUIRES core
    EMBED_FILES ${_splash_embed}
)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wextra -Wno-unused-parameter)
target_compile_definitions(${COMPONENT_LIB} PRIVATE UI_HAVE_SPLASH=${_have_splash})
