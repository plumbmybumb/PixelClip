# Host test suite. Each executable is a self-contained runner using tharness.h.
set(HCA_TESTS test_hca test_fuzz test_scene test_rsvp test_textlay test_oracle test_oracle_reader test_oracle_text test_board)
foreach(t ${HCA_TESTS})
    add_executable(${t} ${t}.c)
    target_link_libraries(${t} PRIVATE hca_core)
    target_include_directories(${t} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../src)
    target_compile_options(${t} PRIVATE -Wall -Wextra -Werror)
    add_test(NAME ${t} COMMAND ${t})
endforeach()

# Decoder throughput benchmark (prints frames/s). Runs as a test too so it is always exercised.
add_executable(bench_decode bench_decode.c)
target_link_libraries(bench_decode PRIVATE hca_core)
target_include_directories(bench_decode PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../src)
target_compile_options(bench_decode PRIVATE -Wall -Wextra -Werror -O2)
add_test(NAME bench_decode COMMAND bench_decode --quick)
set_tests_properties(bench_decode PROPERTIES LABELS bench)
# The sentence reader's shared fixtures (core/fixtures/tarot, also read by the iOS mirror's tests).
target_compile_definitions(test_oracle_reader PRIVATE ORR_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/../fixtures/tarot")
target_compile_definitions(test_oracle_text PRIVATE ORR_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/../fixtures/tarot")
if(NOT APPLE)
    target_link_libraries(test_scene PRIVATE m)   # test_scene uses sinf/cosf (the library itself does not)
endif()
