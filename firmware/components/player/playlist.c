/* playlist.c — playlist JSON validation and persistence (items, time windows, queue). */
#include "playlist.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "cJSON.h"
#include "esp_log.h"
#include "storage.h"
#include "reader_store.h"
#include "oracle_reader.h"
#include "oracle.h"
#include "esp_heap_caps.h"

static const char *TAG = "playlist";
#define PLAYLIST_FILE "playlist.json"
#define EPOCH_MIN 1600000000.0
#define EPOCH_MAX 4102444800.0
static const char *EMPTY_PLAYLIST = "{\"version\":1,\"items\":[]}";

/* Parse context: where we are (for messages) and how strict to be. */
typedef struct {
    bool lenient;          /* stored document: skip what vanished instead of failing */
    bool queue;            /* parsing a queue[] entry rather than an items[] entry */
    int idx;
    char *msg;
    size_t msg_len;
    char bundle_ok[33];    /* the oracle bundle checked last in this document ... */
    uint16_t bundle_cards; /* ... for this many cards: one flash read per bundle, not one per item */
} ctx_t;

#define FAIL(code, ...) do { snprintf(c->msg, c->msg_len, __VA_ARGS__); return (code); } while (0)

static const char *where(const ctx_t *c, char *buf, size_t n)
{
    if (c->idx < 0) {
        snprintf(buf, n, "show");
        return buf;
    }
    snprintf(buf, n, "%s %d", c->queue ? "queue entry" : "item", c->idx);
    return buf;
}

/* A JSON number that is an integer in [lo, hi]. */
static bool num_int(const cJSON *v, double lo, double hi, double *out)
{
    if (!cJSON_IsNumber(v)) return false;
    double d = v->valuedouble;
    if (d != floor(d) || d < lo || d > hi) return false;
    *out = d;
    return true;
}

/* "scroll":{"px_per_s","direction","gap_px","loops"} (PROTOCOL §4 "Scrolling strips"). Every key is
 * optional (defaults 80 px/s, left, 0 px, 1 pass); present keys must be in range. */
static pl_status_t parse_scroll(ctx_t *c, const cJSON *sc, pl_scroll_t *out)
{
    char w[24];
    if (!sc) return PL_OK;
    if (!cJSON_IsObject(sc)) FAIL(PL_ERR_INVALID, "%s: \"scroll\" must be an object", where(c, w, sizeof w));
    pl_scroll_t s = { .on = true, .gap_px = PL_SCROLL_DEF_GAP, .loops = 1, .mpx_per_s = PL_SCROLL_DEF_PX_S * 1000u };
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(sc, "px_per_s");
    if (v) {
        if (!cJSON_IsNumber(v) || !(v->valuedouble >= PL_SCROLL_MIN_PX_S && v->valuedouble <= PL_SCROLL_MAX_PX_S)) {
            FAIL(PL_ERR_INVALID, "%s: scroll.px_per_s must be %d..%d", where(c, w, sizeof w), PL_SCROLL_MIN_PX_S, PL_SCROLL_MAX_PX_S);
        }
        s.mpx_per_s = (uint32_t)lround(v->valuedouble * 1000.0);
    }
    v = cJSON_GetObjectItemCaseSensitive(sc, "direction");
    if (v) {
        if (cJSON_IsString(v) && strcmp(v->valuestring, "left") == 0) {
            s.right = false;
        } else if (cJSON_IsString(v) && strcmp(v->valuestring, "right") == 0) {
            s.right = true;
        } else {
            FAIL(PL_ERR_INVALID, "%s: scroll.direction must be \"left\" or \"right\"", where(c, w, sizeof w));
        }
    }
    double d;
    v = cJSON_GetObjectItemCaseSensitive(sc, "gap_px");
    if (v) {
        if (!num_int(v, 0, PL_SCROLL_MAX_GAP, &d)) FAIL(PL_ERR_INVALID, "%s: scroll.gap_px must be an integer 0..%d", where(c, w, sizeof w), PL_SCROLL_MAX_GAP);
        s.gap_px = (uint16_t)d;
    }
    v = cJSON_GetObjectItemCaseSensitive(sc, "loops");
    if (v) {
        if (!num_int(v, 1, 65535, &d)) FAIL(PL_ERR_INVALID, "%s: scroll.loops must be an integer >= 1", where(c, w, sizeof w));
        s.loops = (uint16_t)d;
        s.loops_set = true;
    }
    *out = s;
    return PL_OK;
}

pl_status_t playlist_parse_scroll(const struct cJSON *scroll, pl_scroll_t *out, char *msg, size_t msg_len)
{
    ctx_t ctx = { .idx = -1, .msg = msg, .msg_len = msg_len };
    *out = (pl_scroll_t){ 0 };
    return parse_scroll(&ctx, (const cJSON *)scroll, out);
}

#if PL_SCENES
static bool json_int(const cJSON *v, int32_t *out)
{
    if (cJSON_IsNumber(v)) {
        double d = v->valuedouble;
        if (d != floor(d) || d < -2147483648.0 || d > 2147483647.0) return false;
        *out = (int32_t)d;
        return true;
    }
    if (cJSON_IsString(v) && v->valuestring[0]) {
        char *end = NULL;
        long long l = strtoll(v->valuestring, &end, 10);
        if (*end != '\0' || l < INT32_MIN || l > INT32_MAX) return false;
        *out = (int32_t)l;
        return true;
    }
    return false;
}

/* Validate `params` against the registry entry and keep the known keys. */
/* §5b.1 the sheet of a `words` scene: "id" (queue entries: "asset", their "id" is the entry's) names an .hca asset of
 * 1..12 frames of w x h (w <= 536, h <= 240, N*w*h <= 514 560 px), one word per frame. A missing asset is
 * unknown_asset (a stored playlist: the item is skipped), wrong sizes invalid_playlist. */
static pl_status_t parse_words_sheet(ctx_t *c, const cJSON *it, pl_item_t *item)
{
    char w[24];
    const char *key = c->queue ? "asset" : "id";
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(it, key);
    if (!cJSON_IsString(id) || !storage_id_valid(id->valuestring)) {
        FAIL(PL_ERR_INVALID, "%s: scene \"words\" needs \"%s\": the sheet's asset id", where(c, w, sizeof w), key);
    }
    strlcpy(item->sheet, id->valuestring, sizeof item->sheet);
    asset_info_t info;
    if (!storage_asset_find(item->sheet, &info)) {
        if (!c->lenient) FAIL(PL_ERR_UNKNOWN_ASSET, "%s: unknown sheet asset \"%s\"", where(c, w, sizeof w), item->sheet);
        ESP_LOGW(TAG, "%s: sheet \"%s\" missing, skipped", where(c, w, sizeof w), item->sheet);
        item->missing = true;
        return PL_OK;
    }
    if (info.strip || info.frames < 1 || info.frames > SCENE_WORDS_MAX || info.width > SCENE_WORDS_MAX_W ||
        info.height > SCENE_WORDS_MAX_H || (uint64_t)info.frames * info.width * info.height > SCENE_WORDS_MAX_PX) {
        if (c->lenient) {
            ESP_LOGW(TAG, "%s: sheet \"%s\" no longer fits (%u frames %ux%u), skipped", where(c, w, sizeof w), item->sheet,
                     (unsigned)info.frames, info.width, info.height);
            item->missing = true;
            return PL_OK;
        }
        FAIL(PL_ERR_INVALID, "%s: sheet \"%s\" must be 1..%d frames of w x h <= %dx%d with N*w*h <= %u px (got %u frames "
             "%ux%u%s)", where(c, w, sizeof w), item->sheet, SCENE_WORDS_MAX, SCENE_WORDS_MAX_W, SCENE_WORDS_MAX_H,
             (unsigned)SCENE_WORDS_MAX_PX, (unsigned)info.frames, info.width, info.height, info.strip ? ", a strip" : "");
    }
    return PL_OK;
}

static pl_status_t parse_scene_params(ctx_t *c, const scene_info_t *si, const cJSON *params, pl_item_t *item)
{
    char w[24];
    scene_params_clear(&item->params);
    if (!params) return PL_OK;
    if (!cJSON_IsObject(params)) FAIL(PL_ERR_INVALID_PARAMS, "%s: \"params\" must be an object", where(c, w, sizeof w));
    const cJSON *kv;
    cJSON_ArrayForEach(kv, params) {
        if (!cJSON_IsString(kv) && !cJSON_IsNumber(kv) && !cJSON_IsBool(kv)) {
            FAIL(PL_ERR_INVALID_PARAMS, "%s: param \"%s\" must be a string, a number or a boolean", where(c, w, sizeof w), kv->string);
        }
        const scene_param_desc_t *d = NULL;
        for (uint8_t i = 0; i < si->param_count && !d; i++) {
            if (strcmp(si->params[i].name, kv->string) == 0) d = &si->params[i];
        }
        if (!d) continue;   /* unknown keys are ignored (PROTOCOL §4) */
        if (d->type == SCENE_PARAM_ENUM) {
            bool ok = false;
            for (uint8_t i = 0; cJSON_IsString(kv) && i < d->value_count && !ok; i++) {
                ok = strcmp(d->values[i], kv->valuestring) == 0;
            }
            if (!ok) FAIL(PL_ERR_INVALID_PARAMS, "%s: %s.%s: not one of the values listed by GET /scenes",
                          where(c, w, sizeof w), si->id, d->name);
            if (!scene_params_set(&item->params, d->name, kv->valuestring)) {
                FAIL(PL_ERR_INVALID_PARAMS, "%s: %s.%s: cannot store", where(c, w, sizeof w), si->id, d->name);
            }
        } else {
            int32_t v = cJSON_IsTrue(kv) ? 1 : 0;   /* PROTOCOL §4: booleans map to 1/0 */
            if ((!cJSON_IsBool(kv) && !json_int(kv, &v)) || v < d->min || v > d->max) {
                FAIL(PL_ERR_INVALID_PARAMS, "%s: %s.%s must be an integer in [%ld, %ld]", where(c, w, sizeof w),
                     si->id, d->name, (long)d->min, (long)d->max);
            }
            if (!scene_params_set_int(&item->params, d->name, v)) {
                FAIL(PL_ERR_INVALID_PARAMS, "%s: %s.%s: cannot store", where(c, w, sizeof w), si->id, d->name);
            }
        }
    }
    return PL_OK;
}

/* Firmware defaults that differ from the core registry's (applied only when the item does not set
 * the key; GET /scenes still reports the registry's own defaults verbatim). */
static const struct { const char *scene, *key; int32_t value; } k_fw_defaults[] = {
    { "fire", "smooth", 1 },   /* the bilinear blend suits flames; crisp blocks look like Minecraft */
};

static void apply_fw_defaults(const scene_info_t *si, scene_params_t *p)
{
    for (size_t i = 0; i < sizeof k_fw_defaults / sizeof k_fw_defaults[0]; i++) {
        if (strcmp(si->id, k_fw_defaults[i].scene) != 0) continue;
        bool set = false;
        for (uint8_t k = 0; k < p->count && !set; k++) set = strcmp(p->kv[k].key, k_fw_defaults[i].key) == 0;
        if (!set) scene_params_set_int(p, k_fw_defaults[i].key, k_fw_defaults[i].value);
    }
}
#endif

/* FNV-1a over a JSON node: type + value; arrays in order, objects as an order-independent sum of
 * (key, value) hashes. Depth-capped (a hostile 1000-level nesting must not blow the player's stack). */
static uint32_t fnv1a(uint32_t h, const void *p, size_t n)
{
    const uint8_t *b = p;
    for (size_t i = 0; i < n; i++) h = (h ^ b[i]) * 16777619u;
    return h;
}

static uint32_t json_node_hash(const cJSON *n, int depth)
{
    uint32_t h = 2166136261u;
    const int type = n->type & 0xFF;
    h = fnv1a(h, &type, sizeof type);
    if (depth > 16) return h;
    if (cJSON_IsNumber(n)) {
        const double d = n->valuedouble;
        h = fnv1a(h, &d, sizeof d);
    } else if ((cJSON_IsString(n) || cJSON_IsRaw(n)) && n->valuestring) {
        h = fnv1a(h, n->valuestring, strlen(n->valuestring));
    } else if (cJSON_IsArray(n)) {
        for (const cJSON *ch = n->child; ch; ch = ch->next) {
            const uint32_t v = json_node_hash(ch, depth + 1);
            h = fnv1a(h, &v, sizeof v);
        }
    } else if (cJSON_IsObject(n)) {
        uint32_t acc = 0;
        for (const cJSON *ch = n->child; ch; ch = ch->next) {
            uint32_t kh = ch->string ? fnv1a(2166136261u, ch->string, strlen(ch->string)) : 0;
            const uint32_t v = json_node_hash(ch, depth + 1);
            kh = fnv1a(kh, &v, sizeof v);
            acc += kh * 2654435761u;
        }
        h = fnv1a(h, &acc, sizeof acc);
    }
    return h;
}

static uint32_t item_hash(const cJSON *it)
{
    const uint32_t h = json_node_hash(it, 0);
    return h ? h : 1;
}

/* The four assets of an oracle item (PROTOCOL §5f). Messages name the asset role and id. */
pl_status_t playlist_oracle_check(const pl_item_t *it, char *msg, size_t msg_len)
{
    const pl_oracle_t *o = &it->orc;
    if (!reader_text_exists(it->id)) {
        snprintf(msg, msg_len, "oracle bundle \"%s\" unknown (PUT /texts first)", it->id);
        return PL_ERR_UNKNOWN_TEXT;
    }
    const char *const fonts[2] = { o->font, o->font_big };
    for (int i = 0; i < 2; i++) {
        if (fonts[i][0] && !reader_font_exists(fonts[i])) {
            snprintf(msg, msg_len, "oracle %s \"%s\" unknown (PUT /fonts first)", i ? "font_big" : "font", fonts[i]);
            return PL_ERR_UNKNOWN_FONT;
        }
    }
    /* §5f.12: the deck 108x206; the keys 160x34, optional (absent: no keyword row) */
    const struct { const char *role, *id; uint16_t w, h; uint32_t frames; } a[2] = {
        { "deck", o->deck, OR_CARD_W, OR_CARD_H, 1u + o->cards },
        { "keys", o->keys, OR_KEY_W, OR_KEY_H, o->cards },
    };
    for (int i = 0; i < 2; i++) {
        if (!a[i].id[0]) continue;   /* (the keys only) */
        asset_info_t info;
        if (!storage_asset_find(a[i].id, &info)) {
            snprintf(msg, msg_len, "oracle %s asset \"%s\" unknown", a[i].role, a[i].id);
            return PL_ERR_UNKNOWN_ASSET;
        }
        if (info.strip || !info.atlas || info.width != a[i].w || info.height != a[i].h || info.frames != a[i].frames) {
            snprintf(msg, msg_len, "oracle %s asset \"%s\" must be %ux%u atlas with %lu frames (got %ux%u%s, %u)", a[i].role,
                     a[i].id, a[i].w, a[i].h, (unsigned long)a[i].frames, info.width, info.height,
                     info.atlas ? " atlas" : info.strip ? " strip" : "", info.frames);
            return PL_ERR_INVALID;
        }
    }
    return PL_OK;
}

/* The bundle's §5f.2 lines: a [prompt] and card.<i>.reading for every card (reads + indexes the text: ~80 KB +
 * ~25 KB, PSRAM when there is some). PL_ERR_INVALID with a message, PL_ERR_JSON when out of memory. */
static pl_status_t oracle_bundle_check(const char *id, uint16_t cards, char *msg, size_t msg_len)
{
    reader_text_info_t info;
    if (!reader_text_info(id, &info) || info.bytes == 0 || info.bytes > PL_OR_BUNDLE_MAX) {
        snprintf(msg, msg_len, "oracle bundle \"%s\" must be 1..%u bytes", id, (unsigned)PL_OR_BUNDLE_MAX);
        return PL_ERR_INVALID;
    }
    char path[96];
    reader_text_path(id, path, sizeof path);
    char *text = heap_caps_malloc(info.bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!text) text = malloc(info.bytes);
    FILE *f = text ? fopen(path, "rb") : NULL;
    const bool ok = f && fread(text, 1, info.bytes, f) == info.bytes;
    if (f) fclose(f);
    void *arena = NULL;
    orr_bundle_t *b = NULL;
    if (ok) {
        const size_t need = orr_arena_bytes(text, info.bytes);
        arena = heap_caps_malloc(need, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!arena) arena = malloc(need);
        b = arena ? orr_parse(text, info.bytes, arena, need) : NULL;
    }
    pl_status_t st = PL_OK;
    if (!b) {
        snprintf(msg, msg_len, "oracle bundle \"%s\" could not be read", id);
        st = text ? PL_ERR_INVALID : PL_ERR_JSON;
    } else {
        size_t n = 0;
        orr_prompt(b, &n);
        if (!n) {
            snprintf(msg, msg_len, "oracle bundle \"%s\" has no [prompt] line", id);
            st = PL_ERR_INVALID;
        }
        for (uint16_t i = 0; i < cards && st == PL_OK; i++) {
            orr_card_field(b, i, ORR_F_READING, &n);
            if (!n) {
                snprintf(msg, msg_len, "oracle bundle \"%s\" has no card.%u.reading (cards %u)", id, i, cards);
                st = PL_ERR_INVALID;
            }
        }
    }
    free(arena);
    free(text);
    return st;
}

/* "board" (PROTOCOL §5g): the sheet ("id"; queue entries "asset"), its rows, header / empty frames and speed. A missing
 * sheet is unknown_asset (a stored playlist: the item is skipped, the frame ranges then unchecked). */
static pl_status_t parse_board(ctx_t *c, const cJSON *it, pl_item_t *item)
{
    char w[24];
    const char *key = c->queue ? "asset" : "id";
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(it, key);
    if (!cJSON_IsString(id) || !storage_id_valid(id->valuestring)) {
        FAIL(PL_ERR_INVALID, "%s: board needs \"%s\": the sheet's asset id", where(c, w, sizeof w), key);
    }
    strlcpy(item->id, id->valuestring, sizeof item->id);
    pl_board_t *b = &item->board;
    memset(b, 0, sizeof *b);
    b->header = b->empty = -1;
    b->speed = 16;
    int frames = PL_BOARD_MAX_FRAMES;   /* (when the sheet is missing in a stored playlist) */
    asset_info_t info;
    if (!storage_asset_find(item->id, &info)) {
        if (!c->lenient) FAIL(PL_ERR_UNKNOWN_ASSET, "%s: unknown sheet asset \"%s\"", where(c, w, sizeof w), item->id);
        ESP_LOGW(TAG, "%s: sheet \"%s\" missing, skipped", where(c, w, sizeof w), item->id);
        item->missing = true;
    } else if (info.strip || info.frames < 1 || info.frames > PL_BOARD_MAX_FRAMES || info.width > 536 ||
               info.height < 16 || info.height > 240 || (uint64_t)info.frames * info.width * info.height > PL_BOARD_MAX_PX) {
        if (c->lenient) {
            ESP_LOGW(TAG, "%s: sheet \"%s\" no longer fits (%u frames %ux%u), skipped", where(c, w, sizeof w), item->id,
                     (unsigned)info.frames, info.width, info.height);
            item->missing = true;
        } else {
            FAIL(PL_ERR_INVALID, "%s: sheet \"%s\" must be 1..48 frames of w x h (w <= 536, 16 <= h <= 240, N*w*h <= "
                 "1048576 px), not a strip (got %u frames %ux%u%s)", where(c, w, sizeof w), item->id, (unsigned)info.frames,
                 info.width, info.height, info.strip ? ", a strip" : "");
        }
    } else {
        frames = (int)info.frames;
    }
    double d;
    static const char *const fkeys[2] = { "header", "empty" };
    int8_t *const fvals[2] = { &b->header, &b->empty };
    for (int i = 0; i < 2; i++) {
        const cJSON *v = cJSON_GetObjectItemCaseSensitive(it, fkeys[i]);
        if (!v || cJSON_IsNull(v)) continue;
        if (!num_int(v, 0, frames - 1, &d)) {
            FAIL(PL_ERR_INVALID, "%s: %s must be a frame 0..%d of the sheet", where(c, w, sizeof w), fkeys[i], frames - 1);
        }
        *fvals[i] = (int8_t)d;
    }
    const cJSON *sp = cJSON_GetObjectItemCaseSensitive(it, "scroll_px_s");
    if (sp) {
        if (!num_int(sp, 4, 60, &d)) FAIL(PL_ERR_INVALID, "%s: scroll_px_s must be an integer 4..60", where(c, w, sizeof w));
        b->speed = (uint8_t)d;
    }
    const cJSON *rows = cJSON_GetObjectItemCaseSensitive(it, "rows");
    const int n = cJSON_IsArray(rows) ? cJSON_GetArraySize(rows) : -1;
    if (n < 1 || n > PL_BOARD_MAX_ROWS) {
        FAIL(PL_ERR_INVALID, "%s: rows must be an array of 1..%d rows", where(c, w, sizeof w), PL_BOARD_MAX_ROWS);
    }
    int i = 0;
    const cJSON *r;
    cJSON_ArrayForEach(r, rows) {
        const cJSON *fr = cJSON_GetObjectItemCaseSensitive(r, "frame");
        if (!cJSON_IsObject(r) || !num_int(fr, 0, frames - 1, &d)) {
            FAIL(PL_ERR_INVALID, "%s: rows[%d].frame must be a frame 0..%d of the sheet", where(c, w, sizeof w), i, frames - 1);
        }
        b->frame[i] = (uint8_t)d;
        const cJSON *un = cJSON_GetObjectItemCaseSensitive(r, "until");
        if (un && !cJSON_IsNull(un)) {
            if (!num_int(un, 0, 4294967295.0, &d)) {
                FAIL(PL_ERR_INVALID, "%s: rows[%d].until must be an integer (unix seconds)", where(c, w, sizeof w), i);
            }
            b->until[i] = (uint32_t)d;
            b->has_until |= 1ull << i;
        }
        i++;
    }
    b->nrows = (uint8_t)i;
    return PL_OK;
}

/* "oracle" (PROTOCOL §5f, §5f.2): the item's id is its reader bundle (a /texts id). */
static pl_status_t parse_oracle(ctx_t *c, const cJSON *it, pl_item_t *item, const char *bundle_id)
{
    char w[24];
    if (!bundle_id || !storage_id_valid(bundle_id)) FAIL(PL_ERR_INVALID, "%s: invalid bundle (text) id", where(c, w, sizeof w));
    strlcpy(item->id, bundle_id, sizeof item->id);
    item->orc = (pl_oracle_t){ .pages = PL_OR_MAX_PAGES, .shake_g = PL_OR_SHAKE_DEF,
                               .face_ms = PL_OR_FACE_DEF_MS, .page_ms = PL_OR_PAGE_DEF_MS, .hold_ms = PL_OR_HOLD_DEF_MS };
    strlcpy(item->orc.reader, bundle_id, sizeof item->orc.reader);
    /* "mode", "daily" and "pages": accepted and ignored for one release (§5f.6: one reading only) */
    double d;
    if (!num_int(cJSON_GetObjectItemCaseSensitive(it, "cards"), PL_OR_MIN_CARDS, PL_OR_MAX_CARDS, &d)) {
        FAIL(PL_ERR_INVALID, "%s: cards must be an integer %d..%d (three distinct cards are drawn)", where(c, w, sizeof w),
             PL_OR_MIN_CARDS, PL_OR_MAX_CARDS);
    }
    item->orc.cards = (uint16_t)d;
    /* "deck" required; "keys" optional (§5f.12: absent -> no keyword row); "notes" (§5f.7) accepted and ignored */
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(it, "deck");
    if (!cJSON_IsString(v) || !storage_id_valid(v->valuestring)) {
        FAIL(PL_ERR_INVALID, "%s: \"deck\" must be an asset id", where(c, w, sizeof w));
    }
    strlcpy(item->orc.deck, v->valuestring, sizeof item->orc.deck);
    item->orc.keys[0] = '\0';
    v = cJSON_GetObjectItemCaseSensitive(it, "keys");
    if (v) {
        if (!cJSON_IsString(v) || !storage_id_valid(v->valuestring)) {
            FAIL(PL_ERR_INVALID, "%s: \"keys\" must be an asset id (or absent)", where(c, w, sizeof w));
        }
        strlcpy(item->orc.keys, v->valuestring, sizeof item->orc.keys);
    }
    v = cJSON_GetObjectItemCaseSensitive(it, "shake_g");
    if (v) {
        if (!cJSON_IsNumber(v) || !(v->valuedouble >= PL_OR_SHAKE_MIN && v->valuedouble <= PL_OR_SHAKE_MAX)) {
            FAIL(PL_ERR_INVALID, "%s: shake_g must be a number 0.4..2.0", where(c, w, sizeof w));
        }
        item->orc.shake_g = (float)v->valuedouble;
    }
    static const char *const tkeys[3] = { "face_ms", "page_ms", "hold_ms" };
    uint32_t *const tvals[3] = { &item->orc.face_ms, &item->orc.page_ms, &item->orc.hold_ms };
    for (int i = 0; i < 3; i++) {
        v = cJSON_GetObjectItemCaseSensitive(it, tkeys[i]);
        if (!v) continue;
        if (!num_int(v, 0, 86400000.0, &d)) FAIL(PL_ERR_INVALID, "%s: %s must be an integer 0..86400000", where(c, w, sizeof w), tkeys[i]);
        *tvals[i] = (uint32_t)d;
    }
    /* "reader" (§5f.1, kept for one release): the same bundle as id */
    v = cJSON_GetObjectItemCaseSensitive(it, "reader");
    if (v && (!cJSON_IsString(v) || strcmp(v->valuestring, bundle_id) != 0)) {
        FAIL(PL_ERR_INVALID, "%s: \"reader\" must be the item's id (the bundle, PROTOCOL §5f.2)", where(c, w, sizeof w));
    }
    /* fonts: "font" required, "font_big" optional */
    v = cJSON_GetObjectItemCaseSensitive(it, "font");
    if (!cJSON_IsString(v) || !storage_id_valid(v->valuestring)) {
        FAIL(PL_ERR_INVALID, "%s: \"font\" must be a font id (the text is drawn with it, PROTOCOL §5f.2)", where(c, w, sizeof w));
    }
    strlcpy(item->orc.font, v->valuestring, sizeof item->orc.font);
    v = cJSON_GetObjectItemCaseSensitive(it, "font_big");
    if (v) {
        if (!cJSON_IsString(v) || !storage_id_valid(v->valuestring)) {
            FAIL(PL_ERR_INVALID, "%s: \"font_big\" must be a font id", where(c, w, sizeof w));
        }
        strlcpy(item->orc.font_big, v->valuestring, sizeof item->orc.font_big);
    }
    char am[160];
    pl_status_t st = playlist_oracle_check(item, am, sizeof am);
    if (st == PL_OK && !(strcmp(c->bundle_ok, item->id) == 0 && item->orc.cards <= c->bundle_cards)) {
        st = oracle_bundle_check(item->id, item->orc.cards, am, sizeof am);
        if (st == PL_OK) {
            strlcpy(c->bundle_ok, item->id, sizeof c->bundle_ok);
            c->bundle_cards = item->orc.cards;
        }
    }
    if (st != PL_OK) {
        if (!c->lenient) FAIL(st, "%s: %s", where(c, w, sizeof w), am);
        ESP_LOGW(TAG, "%s: %s, skipped", where(c, w, sizeof w), am);
        item->missing = true;
    }
    return PL_OK;
}

/* Content + timing fields shared by items[] and queue[]. */
static pl_status_t parse_item(ctx_t *c, const cJSON *it, pl_item_t *item, const appcfg_t *cfg)
{
    char w[24];
    *item = (pl_item_t){ .loops = 1, .from_min = SCHED_NO_WINDOW, .until_min = SCHED_NO_WINDOW,
                         .transition = c->queue ? APPCFG_TRANSITION_FADE : cfg->default_transition };
    const cJSON *type = cJSON_GetObjectItemCaseSensitive(it, "type");
    if (!cJSON_IsObject(it) || !cJSON_IsString(type)) FAIL(PL_ERR_INVALID, "%s: missing \"type\"", where(c, w, sizeof w));
    const char *t = type->valuestring;
    if (strcmp(t, "asset") == 0) {
        item->type = PL_ITEM_ASSET;
        /* Playlist items name the asset "id"; queue entries use "id" for the entry itself. */
        const cJSON *id = cJSON_GetObjectItemCaseSensitive(it, c->queue ? "asset" : "id");
        asset_info_t info;
        if (!cJSON_IsString(id) || !storage_id_valid(id->valuestring)) {
            FAIL(PL_ERR_INVALID, "%s: invalid asset id", where(c, w, sizeof w));
        }
        strlcpy(item->id, id->valuestring, sizeof item->id);
        if (!storage_asset_find(id->valuestring, &info) || info.atlas) {
            if (!c->lenient) FAIL(PL_ERR_UNKNOWN_ASSET, "%s: unknown asset \"%s\"", where(c, w, sizeof w), id->valuestring);
            /* Stored playlist vs. an asset that vanished (dropped at boot as corrupt, failed
             * write...): skip just that item instead of discarding everything. */
            ESP_LOGW(TAG, "%s: asset \"%s\" missing, skipped", where(c, w, sizeof w), id->valuestring);
            item->missing = true;
        }
    } else if (strcmp(t, "scene") == 0) {
        item->type = PL_ITEM_SCENE;
        const cJSON *sc = cJSON_GetObjectItemCaseSensitive(it, "scene");
        if (!cJSON_IsString(sc)) FAIL(PL_ERR_UNKNOWN_SCENE, "%s: missing \"scene\"", where(c, w, sizeof w));
        strlcpy(item->id, sc->valuestring, sizeof item->id);
#if PL_SCENES
        const scene_info_t *si = scene_find(sc->valuestring);
        if (!si) {
            if (!c->lenient) FAIL(PL_ERR_UNKNOWN_SCENE, "%s: unknown scene \"%s\" (see GET /scenes)", where(c, w, sizeof w), sc->valuestring);
            ESP_LOGW(TAG, "%s: scene \"%s\" unknown to this firmware, skipped", where(c, w, sizeof w), sc->valuestring);
            item->missing = true;
        } else {
            pl_status_t st = parse_scene_params(c, si, cJSON_GetObjectItemCaseSensitive(it, "params"), item);
            if (st != PL_OK) {
                if (!c->lenient) return st;
                ESP_LOGW(TAG, "%s", c->msg);
                item->missing = true;
            } else {
                apply_fw_defaults(si, &item->params);
            }
            if (si->kind == SCENE_WORDS) {
                st = parse_words_sheet(c, it, item);
                if (st != PL_OK) return st;
            }
        }
#else
        if (!c->lenient) FAIL(PL_ERR_UNKNOWN_SCENE, "%s: live scenes are not supported by this firmware", where(c, w, sizeof w));
        item->missing = true;
#endif
    } else if (strcmp(t, "reader") == 0) {
        item->type = PL_ITEM_READER;
        item->wpm = PL_READER_WPM_DEF;
        const cJSON *tx = cJSON_GetObjectItemCaseSensitive(it, "text");
        const cJSON *fo = cJSON_GetObjectItemCaseSensitive(it, "font");
        if (!cJSON_IsString(tx) || !storage_id_valid(tx->valuestring)) FAIL(PL_ERR_INVALID, "%s: \"text\" must be a text id", where(c, w, sizeof w));
        if (!cJSON_IsString(fo) || !storage_id_valid(fo->valuestring)) FAIL(PL_ERR_INVALID, "%s: \"font\" must be a font id", where(c, w, sizeof w));
        strlcpy(item->id, tx->valuestring, sizeof item->id);
        strlcpy(item->font, fo->valuestring, sizeof item->font);
        if (!reader_text_exists(item->id)) {
            if (!c->lenient) FAIL(PL_ERR_UNKNOWN_TEXT, "%s: unknown text \"%s\" (PUT /texts first)", where(c, w, sizeof w), item->id);
            ESP_LOGW(TAG, "%s: text \"%s\" missing, skipped", where(c, w, sizeof w), item->id);
            item->missing = true;
        }
        if (!reader_font_exists(item->font)) {
            if (!c->lenient) FAIL(PL_ERR_UNKNOWN_FONT, "%s: unknown font \"%s\" (PUT /fonts first)", where(c, w, sizeof w), item->font);
            ESP_LOGW(TAG, "%s: font \"%s\" missing, skipped", where(c, w, sizeof w), item->font);
            item->missing = true;
        }
        double d;
        const cJSON *v = cJSON_GetObjectItemCaseSensitive(it, "wpm");
        if (v) {
            if (!num_int(v, PL_READER_WPM_MIN, PL_READER_WPM_MAX, &d)) {
                FAIL(PL_ERR_INVALID, "%s: wpm must be an integer %d..%d", where(c, w, sizeof w), PL_READER_WPM_MIN, PL_READER_WPM_MAX);
            }
            item->wpm = (uint16_t)d;
        }
        v = cJSON_GetObjectItemCaseSensitive(it, "from_word");
        if (v) {
            if (!num_int(v, 0, 4294967295.0, &d)) FAIL(PL_ERR_INVALID, "%s: from_word must be an integer >= 0", where(c, w, sizeof w));
            item->from_word = (uint32_t)d;
        }
        v = cJSON_GetObjectItemCaseSensitive(it, "loop");
        if (v) {
            if (!cJSON_IsBool(v)) FAIL(PL_ERR_INVALID, "%s: loop must be true or false", where(c, w, sizeof w));
            item->loop = cJSON_IsTrue(v);
        }
    } else if (strcmp(t, "oracle") == 0) {
        item->type = PL_ITEM_ORACLE;
        const cJSON *id = cJSON_GetObjectItemCaseSensitive(it, c->queue ? "asset" : "id");
        pl_status_t ost = parse_oracle(c, it, item, cJSON_IsString(id) ? id->valuestring : NULL);
        if (ost != PL_OK) return ost;
    } else if (strcmp(t, "board") == 0) {
        item->type = PL_ITEM_BOARD;
        pl_status_t bst = parse_board(c, it, item);
        if (bst != PL_OK) return bst;
    } else if (!c->queue && strcmp(t, "clock") == 0) {
        item->type = PL_ITEM_CLOCK;
    } else if (!c->queue && strcmp(t, "text") == 0) {
        item->type = PL_ITEM_TEXT;
    } else {
        FAIL(PL_ERR_INVALID, "%s: unknown type \"%s\"", where(c, w, sizeof w), t);
    }

    const cJSON *d = cJSON_GetObjectItemCaseSensitive(it, "duration_ms");
    if (d) {
        if (!cJSON_IsNumber(d) || d->valuedouble < 0 || d->valuedouble > 86400000.0) {
            FAIL(PL_ERR_INVALID, "%s: duration_ms must be 0..86400000", where(c, w, sizeof w));
        }
        item->duration_ms = (uint32_t)d->valuedouble;
    }
    const cJSON *l = cJSON_GetObjectItemCaseSensitive(it, "loops");
    if (l) {
        if (!cJSON_IsNumber(l) || l->valuedouble < 0 || l->valuedouble > 65535) {
            FAIL(PL_ERR_INVALID, "%s: loops must be 0..65535", where(c, w, sizeof w));
        }
        item->loops = l->valueint < 1 ? 1 : (uint16_t)l->valueint;
    }
    const cJSON *tr = cJSON_GetObjectItemCaseSensitive(it, "transition");
    if (tr) {
        if (cJSON_IsString(tr) && strcmp(tr->valuestring, "cut") == 0) {
            item->transition = APPCFG_TRANSITION_CUT;
        } else if (cJSON_IsString(tr) && strcmp(tr->valuestring, "fade") == 0) {
            item->transition = APPCFG_TRANSITION_FADE;
        } else {
            FAIL(PL_ERR_INVALID, "%s: transition must be \"cut\" or \"fade\"", where(c, w, sizeof w));
        }
    }
    pl_status_t sst = parse_scroll(c, cJSON_GetObjectItemCaseSensitive(it, "scroll"), &item->scroll);
    if (sst != PL_OK) return sst;
    const cJSON *seed = cJSON_GetObjectItemCaseSensitive(it, "seed");
    if (seed && item->type == PL_ITEM_SCENE) {
        double sd;
        if (!num_int(seed, 0, 4294967295.0, &sd)) FAIL(PL_ERR_INVALID, "%s: seed must be an integer 0..4294967295", where(c, w, sizeof w));
        item->has_seed = true;
        item->seed = (uint32_t)sd;
    }
    if (!c->queue) {
        const cJSON *from = cJSON_GetObjectItemCaseSensitive(it, "from");
        const cJSON *until = cJSON_GetObjectItemCaseSensitive(it, "until");
        if (from && (!cJSON_IsString(from) || !sched_parse_hhmm(from->valuestring, &item->from_min) ||
                     item->from_min >= 24 * 60)) {
            FAIL(PL_ERR_INVALID, "%s: \"from\" must be \"HH:MM\" (00:00..23:59)", where(c, w, sizeof w));
        }
        if (until && (!cJSON_IsString(until) || !sched_parse_hhmm(until->valuestring, &item->until_min))) {
            FAIL(PL_ERR_INVALID, "%s: \"until\" must be \"HH:MM\" (00:00..24:00)", where(c, w, sizeof w));
        }
        int16_t f = item->from_min == SCHED_NO_WINDOW ? 0 : item->from_min;
        int16_t u = item->until_min == SCHED_NO_WINDOW ? 24 * 60 : item->until_min;
        if (sched_has_window(item->from_min, item->until_min) && f == u) {
            FAIL(PL_ERR_INVALID, "%s: empty time window (\"from\" == \"until\")", where(c, w, sizeof w));
        }
    }
    return PL_OK;
}

static pl_status_t parse_queue(ctx_t *c, const cJSON *queue, playlist_t *out, const appcfg_t *cfg)
{
    char w[24];
    if (!queue) return PL_OK;
    if (!cJSON_IsArray(queue)) FAIL(PL_ERR_JSON, "\"queue\" must be an array");
    if (cJSON_GetArraySize(queue) > PLAYLIST_MAX_QUEUE) FAIL(PL_ERR_INVALID, "at most %d queue entries", PLAYLIST_MAX_QUEUE);
    c->queue = true;
    c->idx = 0;
    const cJSON *e;
    cJSON_ArrayForEach(e, queue) {
        pl_queue_entry_t qe = { 0 };
        if (!cJSON_IsObject(e)) FAIL(PL_ERR_INVALID, "%s: must be an object", where(c, w, sizeof w));
        const cJSON *id = cJSON_GetObjectItemCaseSensitive(e, "id");
        const cJSON *at = cJSON_GetObjectItemCaseSensitive(e, "at");
        if (!cJSON_IsString(id) || !sched_id_valid(id->valuestring)) {
            FAIL(PL_ERR_INVALID, "%s: \"id\" must be 1..%d printable characters", where(c, w, sizeof w), SCHED_ID_MAX);
        }
        for (const cJSON *p = queue->child; p && p != e; p = p->next) {
            const cJSON *pid = cJSON_GetObjectItemCaseSensitive(p, "id");
            if (cJSON_IsString(pid) && strcmp(pid->valuestring, id->valuestring) == 0) {
                FAIL(PL_ERR_INVALID, "%s: duplicate id \"%s\"", where(c, w, sizeof w), id->valuestring);
            }
        }
        if (!cJSON_IsNumber(at) || at->valuedouble < EPOCH_MIN || at->valuedouble > EPOCH_MAX) {
            FAIL(PL_ERR_INVALID, "%s: \"at\" must be unix seconds", where(c, w, sizeof w));
        }
        strlcpy(qe.id, id->valuestring, sizeof qe.id);
        qe.at = (int64_t)at->valuedouble;
        pl_status_t st = parse_item(c, e, &qe.item, cfg);
        if (st != PL_OK) return st;
        if (out) qe.item.json_hash = item_hash(e);
        /* The queue's own default (PROTOCOL §4: "for duration_ms (default 60 s)") also covers scrolling
         * strips: such an entry scrolls an endless tape for 60 s rather than `loops` passes (as the app's
         * PlaybackEngine models it). */
        if (qe.item.duration_ms == 0) qe.item.duration_ms = SCHED_DEFAULT_MS;
        if (out) {
            /* Insertion sort by `at` (stable for equal times). */
            size_t k = out->queue_count;
            while (k > 0 && out->queue[k - 1].at > qe.at) {
                out->queue[k] = out->queue[k - 1];
                k--;
            }
            out->queue[k] = qe;
            out->queue_count++;
        }
        c->idx++;
    }
    return PL_OK;
}

static pl_status_t parse(const char *json, size_t len, playlist_t *out, char *msg, size_t msg_len, bool lenient)
{
    appcfg_t cfg;
    appcfg_get(&cfg);
    ctx_t ctx = { .lenient = lenient, .msg = msg, .msg_len = msg_len }, *c = &ctx;
    cJSON *root = cJSON_ParseWithLength(json, len);
    pl_status_t st = PL_OK;
    if (out) out->count = out->queue_count = 0;
    if (!cJSON_IsObject(root)) {
        snprintf(msg, msg_len, "playlist must be a JSON object");
        st = PL_ERR_JSON;
        goto done;
    }
    const cJSON *ver = cJSON_GetObjectItemCaseSensitive(root, "version");
    if (ver && (!cJSON_IsNumber(ver) || ver->valueint != 1)) {
        snprintf(msg, msg_len, "unsupported playlist version");
        st = PL_ERR_INVALID;
        goto done;
    }
    const cJSON *items = cJSON_GetObjectItemCaseSensitive(root, "items");
    if (!cJSON_IsArray(items)) {
        snprintf(msg, msg_len, "\"items\" must be an array");
        st = PL_ERR_JSON;
        goto done;
    }
    if (cJSON_GetArraySize(items) > PLAYLIST_MAX_ITEMS) {
        snprintf(msg, msg_len, "at most %d items", PLAYLIST_MAX_ITEMS);
        st = PL_ERR_INVALID;
        goto done;
    }
    const cJSON *it;
    cJSON_ArrayForEach(it, items) {
        pl_item_t item;
        st = parse_item(c, it, &item, &cfg);
        if (st != PL_OK) goto done;
        if (out) item.json_hash = item_hash(it);
        /* Vanished assets are dropped from the rotation (as before); missing scenes too. */
        if (out && !item.missing) out->items[out->count++] = item;
        ctx.idx++;
    }
    /* Queue entries are kept even when their content vanished, so their id stays known (done-state
     * is keyed by id); the player marks them skipped when they come due. */
    st = parse_queue(c, cJSON_GetObjectItemCaseSensitive(root, "queue"), out, &cfg);
done:
    cJSON_Delete(root);
    if (st != PL_OK && out) out->count = out->queue_count = 0;
    return st;
}

pl_status_t playlist_parse(const char *json, size_t len, playlist_t *out, char *msg, size_t msg_len)
{
    return parse(json, len, out, msg, msg_len, false);
}

pl_status_t playlist_parse_show_item(const struct cJSON *obj, const char *id, pl_item_t *out, char *msg, size_t msg_len)
{
    appcfg_t cfg;
    appcfg_get(&cfg);
    ctx_t ctx = { .idx = -1, .msg = msg, .msg_len = msg_len };
    const cJSON *type = cJSON_GetObjectItemCaseSensitive((const cJSON *)obj, "type");
    if (!cJSON_IsObject((const cJSON *)obj) || !cJSON_IsString(type) ||
        (strcmp(type->valuestring, "oracle") != 0 && strcmp(type->valuestring, "scene") != 0 &&
         strcmp(type->valuestring, "board") != 0)) {
        snprintf(msg, msg_len, "show: only \"type\":\"oracle\", \"scene\" or \"board\" items can be shown with a body");
        return PL_ERR_INVALID;
    }
    /* the path names the asset: validate a copy whose "id" is the path's */
    cJSON *copy = cJSON_Duplicate((const cJSON *)obj, true);
    if (!copy || (cJSON_DeleteItemFromObjectCaseSensitive(copy, "id"), !cJSON_AddStringToObject(copy, "id", id))) {
        cJSON_Delete(copy);
        snprintf(msg, msg_len, "no memory");
        return PL_ERR_JSON;
    }
    pl_status_t st = parse_item(&ctx, copy, out, &cfg);
    if (st == PL_OK) out->json_hash = item_hash(copy);
    cJSON_Delete(copy);
    return st;
}

esp_err_t playlist_store(const char *json, size_t len)
{
    return storage_write_file(PLAYLIST_FILE, json, len);
}

bool playlist_set_aside(void)
{
    if (storage_file_size(PLAYLIST_FILE) < 0) return false;
    if (storage_rename_file(PLAYLIST_FILE, "playlist.bad.json") != ESP_OK) storage_remove_file(PLAYLIST_FILE);
    return true;
}

char *playlist_read_json(void)
{
    char *buf = NULL;
    if (storage_read_file(PLAYLIST_FILE, &buf, NULL, PLAYLIST_MAX_BYTES) != ESP_OK) {
        buf = strdup(EMPTY_PLAYLIST);
    }
    return buf;
}

void playlist_load(playlist_t *out)
{
    out->count = out->queue_count = 0;
    char *buf = NULL;
    size_t len = 0;
    if (storage_read_file(PLAYLIST_FILE, &buf, &len, PLAYLIST_MAX_BYTES) != ESP_OK) return;
    char msg[128] = "";
    pl_status_t st = parse(buf, len, out, msg, sizeof msg, true);
    if (st != PL_OK) ESP_LOGW(TAG, "stored playlist invalid (%s), treating as empty", msg);
    free(buf);
    ESP_LOGI(TAG, "%u item(s), %u queue entr%s", (unsigned)out->count, (unsigned)out->queue_count,
             out->queue_count == 1 ? "y" : "ies");
}

static bool ref1(const cJSON *it, const char *type_name, const char *key, const char *id)
{
    const cJSON *type = cJSON_GetObjectItemCaseSensitive(it, "type");
    const cJSON *iid = cJSON_GetObjectItemCaseSensitive(it, key);
    return cJSON_IsString(type) && strcmp(type->valuestring, type_name) == 0 &&
           cJSON_IsString(iid) && strcmp(iid->valuestring, id) == 0;
}

static bool refs(const cJSON *it, const char *type_name, const char *key, const char *id)
{
    return ref1(it, type_name, key, id);
}

/* Drop items whose `item_key` and queue entries whose `queue_key` reference `id` (type `type_name`). */
static esp_err_t remove_refs(const char *type_name, const char *item_key, const char *queue_key, const char *id)
{
    char *buf = NULL;
    size_t len = 0;
    if (storage_read_file(PLAYLIST_FILE, &buf, &len, PLAYLIST_MAX_BYTES) != ESP_OK) return ESP_OK;
    cJSON *root = cJSON_ParseWithLength(buf, len);
    free(buf);
    cJSON *items = cJSON_GetObjectItemCaseSensitive(root, "items");
    if (!cJSON_IsArray(items)) {
        cJSON_Delete(root);
        return ESP_OK;
    }
    bool changed = false;
    for (int i = cJSON_GetArraySize(items) - 1; i >= 0; i--) {
        if (refs(cJSON_GetArrayItem(items, i), type_name, item_key, id)) {
            cJSON_DeleteItemFromArray(items, i);
            changed = true;
        }
    }
    cJSON *queue = cJSON_GetObjectItemCaseSensitive(root, "queue");
    for (int i = cJSON_IsArray(queue) ? cJSON_GetArraySize(queue) - 1 : -1; i >= 0; i--) {
        if (refs(cJSON_GetArrayItem(queue, i), type_name, queue_key, id)) {
            cJSON_DeleteItemFromArray(queue, i);
            changed = true;
        }
    }
    esp_err_t err = ESP_OK;
    if (changed) {
        char *s = cJSON_PrintUnformatted(root);
        err = s ? playlist_store(s, strlen(s)) : ESP_ERR_NO_MEM;
        cJSON_free(s);
        ESP_LOGI(TAG, "removed %s %s from playlist", type_name, id);
    }
    cJSON_Delete(root);
    return err;
}

esp_err_t playlist_remove_asset(const char *id)
{
    esp_err_t err = remove_refs("asset", "id", "asset", id);
    /* oracle items using it as their deck or keys (no T since §5f.2, no N since §5f.7) */
    static const char *const keys[2] = { "deck", "keys" };
    for (int i = 0; i < 2; i++) {
        const esp_err_t eo = remove_refs("oracle", keys[i], keys[i], id);
        if (err == ESP_OK) err = eo;
    }
    const esp_err_t e = remove_refs("scene", "id", "asset", id);   /* §5b.1 words items whose sheet it is (other scenes
                                                                      ignore "id"; one naming this asset goes too) */
    const esp_err_t eb = remove_refs("board", "id", "asset", id);  /* §5g boards whose sheet it is */
    return err != ESP_OK ? err : e != ESP_OK ? e : eb;
}

/* §5b.1 a words scene of the stored playlist (items: "id", queue entries: "asset") uses this sheet. */
bool playlist_words_uses(const char *sheet_id)
{
    char *buf = NULL;
    size_t len = 0;
    if (!sheet_id || storage_read_file(PLAYLIST_FILE, &buf, &len, PLAYLIST_MAX_BYTES) != ESP_OK) return false;
    cJSON *root = cJSON_ParseWithLength(buf, len);
    free(buf);
    bool found = false;
    static const char *const lists[2] = { "items", "queue" };
    for (int l = 0; l < 2 && !found; l++) {
        const cJSON *it;
        cJSON_ArrayForEach(it, cJSON_GetObjectItemCaseSensitive(root, lists[l])) {
            const cJSON *sc = cJSON_GetObjectItemCaseSensitive(it, "scene");
            if ((ref1(it, "scene", l ? "asset" : "id", sheet_id) && cJSON_IsString(sc) && strcmp(sc->valuestring, "words") == 0) ||
                ref1(it, "board", l ? "asset" : "id", sheet_id)) {   /* §5g a board's sheet too */
                found = true;
                break;
            }
        }
    }
    cJSON_Delete(root);
    return found;
}

bool playlist_oracle_uses(const char *bundle_id)
{
    char *buf = NULL;
    size_t len = 0;
    if (!bundle_id || storage_read_file(PLAYLIST_FILE, &buf, &len, PLAYLIST_MAX_BYTES) != ESP_OK) return false;
    cJSON *root = cJSON_ParseWithLength(buf, len);
    free(buf);
    bool found = false;
    static const char *const lists[2] = { "items", "queue" };
    for (int l = 0; l < 2 && !found; l++) {
        const cJSON *arr = cJSON_GetObjectItemCaseSensitive(root, lists[l]);
        const cJSON *it;
        cJSON_ArrayForEach(it, arr) {
            if (ref1(it, "oracle", l ? "asset" : "id", bundle_id)) {
                found = true;
                break;
            }
        }
    }
    cJSON_Delete(root);
    return found;
}

/* A deleted text / font: the reader items using it, and the oracle items whose bundle (id) / body font it is. */
esp_err_t playlist_remove_reader(const char *key, const char *id)
{
    esp_err_t err = remove_refs("reader", key, key, id);
    const bool text = strcmp(key, "text") == 0;
    const esp_err_t err2 = remove_refs("oracle", text ? "id" : "font", text ? "asset" : "font", id);
    return err != ESP_OK ? err : err2;
}

bool playlist_item_in_window(const pl_item_t *it, int64_t now, int32_t tz_offset_s, bool clock_synced)
{
    if (!sched_has_window(it->from_min, it->until_min)) return true;
    return clock_synced && sched_window_contains(it->from_min, it->until_min, now, tz_offset_s);
}
