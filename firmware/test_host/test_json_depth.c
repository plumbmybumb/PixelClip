/* test_json_depth.c — host regression test for the JSON nesting cap (security audits WIFI-3 / PARSE-1).
 *
 * Built from ESP-IDF's own cJSON.c with the firmware's CJSON_NESTING_LIMIT (json_limit.cmake). Every JSON
 * document the clip parses (request bodies in net/http_api.c, the stored playlist in player/playlist.c, the
 * config, fonts, the queue's done-set) goes through cJSON_ParseWithLength() of this source. Before the cap a
 * body of 200 '[' overflowed the httpd stack, and a PUT /playlist with an ignored key nested about 100 deep
 * was stored and then overflowed the player's and the main task's stack at every boot.
 *
 * What is checked: the cap is the firmware's number, documents at the cap parse, documents one level deeper
 * (and the audit's payloads) come back as NULL, which the callers treat as "not JSON": read_json() answers
 * 400 bad_json, playlist_parse() PL_ERR_JSON, playlist_load() "stored playlist invalid, treating as empty". */
#include "cJSON.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int s_fail, s_checks;
#define CHECK(c) do { s_checks++; if (!(c)) { s_fail++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

_Static_assert(CJSON_NESTING_LIMIT == 16, "the host test must build cJSON with the firmware's cap");

/* `depth` nested arrays: "[[[...]]]" (closed) or only the opening brackets (the parser recurses before it fails). */
static char *arrays(int depth, int closed)
{
    char *s = malloc((size_t)depth * 2 + 1);
    memset(s, '[', (size_t)depth);
    if (closed) memset(s + depth, ']', (size_t)depth);
    s[depth * (closed ? 2 : 1)] = '\0';
    return s;
}

/* `depth` nested objects: {"a":{"a":...{}...}} */
static char *objects(int depth)
{
    char *s = malloc((size_t)depth * 6 + 1), *p = s;
    for (int i = 0; i < depth - 1; i++) { memcpy(p, "{\"a\":", 5); p += 5; }
    *p++ = '{';
    for (int i = 0; i < depth; i++) *p++ = '}';
    *p = '\0';
    return s;
}

static int parses(const char *s)
{
    cJSON *j = cJSON_ParseWithLength(s, strlen(s));
    const int ok = j != NULL;
    cJSON_Delete(j);
    return ok;
}

/* The audit's persistent payload: a valid playlist with an ignored top-level key nested `depth` arrays deep. */
static char *poisoned_playlist(int depth)
{
    static const char head[] = "{\"version\":1,\"items\":[],\"x\":";
    char *a = arrays(depth, 1);
    const size_t cap = sizeof head + strlen(a) + 2;
    char *s = malloc(cap);
    snprintf(s, cap, "%s%s}", head, a);
    free(a);
    return s;
}

int main(void)
{
    char *s;

    /* At the cap: accepted. One deeper: rejected. */
    s = arrays(CJSON_NESTING_LIMIT, 1);      CHECK(parses(s));  free(s);
    s = arrays(CJSON_NESTING_LIMIT + 1, 1);  CHECK(!parses(s)); free(s);
    s = objects(CJSON_NESTING_LIMIT);        CHECK(parses(s));  free(s);
    s = objects(CJSON_NESTING_LIMIT + 1);    CHECK(!parses(s)); free(s);

    /* The audit's transient payloads: 200 unclosed '[' (POST /time), depth 1000 (2 KB), and deeper. */
    s = arrays(200, 0);    CHECK(!parses(s)); free(s);
    s = arrays(1000, 1);   CHECK(!parses(s)); free(s);
    s = arrays(100000, 0); CHECK(!parses(s)); free(s);

    /* The audit's persistent payload (PUT /playlist, then every boot): the root object is level 1. */
    s = poisoned_playlist(CJSON_NESTING_LIMIT - 1); CHECK(parses(s));  free(s);
    s = poisoned_playlist(CJSON_NESTING_LIMIT);     CHECK(!parses(s)); free(s);
    s = poisoned_playlist(100);                     CHECK(!parses(s)); free(s);
    s = poisoned_playlist(115);                     CHECK(!parses(s)); free(s);

    /* A rejected document is NULL, so the callers' cJSON_IsObject() check is what turns it into an error. */
    s = poisoned_playlist(100);
    cJSON *j = cJSON_ParseWithLength(s, strlen(s));
    CHECK(j == NULL && !cJSON_IsObject(j));
    cJSON_Delete(j);
    free(s);

    /* Real documents stay far below the cap (PROTOCOL.md: a playlist with a scene, a scroll, a board and a queue). */
    CHECK(parses("{\"version\":1,\"items\":["
                 "{\"type\":\"scene\",\"scene\":\"sand\",\"params\":{\"palette\":\"amber\",\"density\":60},\"duration_ms\":30000},"
                 "{\"type\":\"asset\",\"id\":\"strip\",\"scroll\":{\"px_per_s\":80,\"direction\":\"left\",\"gap_px\":120,\"loops\":2}},"
                 "{\"type\":\"board\",\"id\":\"b\",\"rows\":[{\"frame\":2,\"until\":1761062400},{\"frame\":3}]}],"
                 "\"queue\":[{\"id\":\"q\",\"at\":1761062400,\"type\":\"scene\",\"scene\":\"balls\",\"params\":{\"count\":12}}]}"));

    printf("%d checks, %d failed (CJSON_NESTING_LIMIT %d)\n", s_checks, s_fail, CJSON_NESTING_LIMIT);
    return s_fail ? 1 : 0;
}
