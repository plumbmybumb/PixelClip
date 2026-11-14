# Host tools. Built from core/CMakeLists.txt (HCA_BUILD_TOOLS=ON, the default on the host).
add_library(stb_image_impl STATIC third_party/stb_image_impl.c)
target_compile_options(stb_image_impl PRIVATE -w)
target_include_directories(stb_image_impl PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

foreach(tool hcaenc hcainfo hcadec mkfixtures scene_preview rsvp_preview)
    add_executable(${tool} ${tool}.c)
    target_include_directories(${tool} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_options(${tool} PRIVATE -Wall -Wextra -Werror)
    target_link_libraries(${tool} PRIVATE hca_core)
endforeach()
target_link_libraries(hcaenc PRIVATE stb_image_impl)
if(NOT APPLE)
    target_link_libraries(mkfixtures PRIVATE m)
endif()

# Smoke test the tool chain end to end on the generated fixtures.
if(HCA_BUILD_TESTS)
    add_test(NAME tools_fixtures
             COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/fixtures/make_fixtures.sh
                     --bindir $<TARGET_FILE_DIR:hcaenc> --out ${CMAKE_CURRENT_BINARY_DIR}/fixtures-check)
endif()
