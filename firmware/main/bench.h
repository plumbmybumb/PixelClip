/* bench.h — light-sleep soak harness, compiled in with CONFIG_PIXELCLIP_BENCH_SLEEP_TEST (see bench.c). */
#pragma once
#include <stdbool.h>

/* Called with true to start an upload session, false to end it (from the bench task: post an event). */
typedef void (*bench_post_fn_t)(bool start);

/* No-op unless CONFIG_PIXELCLIP_BENCH_SLEEP_TEST. */
void bench_start(bench_post_fn_t post);
