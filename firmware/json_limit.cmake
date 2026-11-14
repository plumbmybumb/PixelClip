# The JSON nesting cap of this firmware (security audits WIFI-3 and PARSE-1), shared by the firmware build (CMakeLists.txt)
# and the host tests (test_host/CMakeLists.txt) so that both build cJSON with the same number.
#
# cJSON's parser recurses once per nesting level and ESP-IDF ships it with CJSON_NESTING_LIMIT 1000 (cJSON.h,
# under #ifndef). A body of a few hundred '[' then overflows the 8 to 10 KB task stacks that parse JSON here
# (httpd, the BLE fast-lane worker, the player, main): the parser takes 64 B of stack per level, the printer 96,
# the duplicator 48, the deleter 32 (measured in the built ELF). 16 levels cost at most 1.5 KB, the same bound
# as json_node_hash in player/playlist.c and the font parser's JSON_MAX_DEPTH; no document of PROTOCOL.md
# nests deeper than 5 (security audits WIFI-3 and PARSE-1).
set(PIXELCLIP_JSON_NESTING_LIMIT 16)
