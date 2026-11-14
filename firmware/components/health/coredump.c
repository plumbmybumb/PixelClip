/* coredump.c — the ELF core dump in the `coredump` flash partition (health.h, README "Crash diagnostics").
 *
 * IDF's panic handler writes the dump (CONFIG_ESP_COREDUMP_ENABLE_TO_FLASH); this file reports it at boot,
 * serves it to GET /coredump and erases it for DELETE /coredump. Every IDF core dump call is guarded by our
 * own partition lookup: those calls log "No core dump partition found!" as an error otherwise, and a clip
 * updated over OTA keeps its old partition table, which has no coredump partition.
 */
#include "health.h"
#include "health_priv.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_core_dump.h"
#include "esp_partition.h"
#include "esp_app_desc.h"
#include "esp_log.h"

static const char *TAG = "health";

#define BLANK_WORD   0xFFFFFFFFu
#define MIN_IMAGE    64u          /* header (24 B) + ELF header (52 B) is already more than this */

static int32_t s_size = -1;       /* size of the valid stored image; -1 = not probed yet */

static const esp_partition_t *cd_part(void)
{
    return esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_COREDUMP, NULL);
}

/* Linked with -Wl,--wrap=esp_core_dump_init (CMakeLists.txt). IDF's startup hook logs
 * "E ... esp_core_dump_flash: No core dump partition found!" at every boot when the partition table has none
 * (a clip updated over OTA from the old layout). Without a partition its flash config stays empty, so a panic
 * then just skips the dump ("Core dump flash config is corrupted!" in the panic output) and reboots as before. */
void __real_esp_core_dump_init(void);
void __wrap_esp_core_dump_init(void);
void __wrap_esp_core_dump_init(void)
{
    if (cd_part()) __real_esp_core_dump_init();
}

/* Size of the valid image, 0 when there is none. *why = what is wrong with a non-blank invalid image. */
static size_t probe(const char **why, uint32_t *word_out)
{
    *why = NULL;
    *word_out = BLANK_WORD;
    const esp_partition_t *p = cd_part();
    if (!p) return 0;
    uint32_t word = BLANK_WORD;
    if (esp_partition_read(p, 0, &word, sizeof word) != ESP_OK) {
        *why = "unreadable";
        return 0;
    }
    *word_out = word;
    if (word == BLANK_WORD) return 0;                       /* erased: no dump */
    if (word < MIN_IMAGE || word > p->size) {
        *why = "size word out of range (old data from an earlier partition layout?)";
        return 0;
    }
    const esp_err_t err = esp_core_dump_image_check();      /* SHA-256 over the whole image */
    if (err != ESP_OK) {
        *why = err == ESP_ERR_INVALID_CRC ? "checksum mismatch (dump interrupted?)" : esp_err_to_name(err);
        return 0;
    }
    return word;
}

size_t health_coredump_size(void)
{
    if (s_size < 0) {
        const char *why;
        uint32_t word;
        s_size = (int32_t)probe(&why, &word);
    }
    return (size_t)s_size;
}

esp_err_t health_coredump_read(size_t off, void *buf, size_t len)
{
    const esp_partition_t *p = cd_part();
    const size_t size = health_coredump_size();
    if (!p || size == 0) return ESP_ERR_NOT_FOUND;
    if (off > size || len > size - off) return ESP_ERR_INVALID_SIZE;
    return esp_partition_read(p, off, buf, len);
}

esp_err_t health_coredump_erase(void)
{
    /* An invalid image was already cleared by the boot report, so "no valid image" = nothing to erase. */
    if (!cd_part() || health_coredump_size() == 0) return ESP_ERR_NOT_FOUND;
    const esp_err_t err = esp_core_dump_image_erase();
    if (err == ESP_OK) s_size = 0;
    if (err == ESP_OK) ESP_LOGI(TAG, "core dump erased");
    return err;
}

/* Xtensa EXCCAUSE names, as in IDF's panic handler (components/esp_system/port/arch/xtensa/panic_arch.c). */
static const char *exccause_name(uint32_t c)
{
    static const char *const names[] = {
        "IllegalInstruction", "Syscall", "InstructionFetchError", "LoadStoreError",
        "Level1Interrupt", "Alloca", "IntegerDivideByZero", "PCValue",
        "Privileged", "LoadStoreAlignment", "res", "res",
        "InstrPDAddrError", "LoadStorePIFDataError", "InstrPIFAddrError", "LoadStorePIFAddrError",
        "InstTLBMiss", "InstTLBMultiHit", "InstFetchPrivilege", "res",
        "InstrFetchProhibited", "res", "res", "res",
        "LoadStoreTLBMiss", "LoadStoreTLBMultihit", "LoadStorePrivilege", "res",
        "LoadProhibited", "StoreProhibited", "res", "res",
        "Cp0Dis", "Cp1Dis", "Cp2Dis", "Cp3Dis",
        "Cp4Dis", "Cp5Dis", "Cp6Dis", "Cp7Dis",
    };
    return c < sizeof names / sizeof names[0] ? names[c] : "?";
}

/* The panic details text (abort / assert message, task watchdog report) on one line, and without the
 * phrases flash.sh / sleep_soak.sh treat as a panic of the *current* run (this one is history). */
static void defang(char *s)
{
    static const char *const from[] = { "abort() was called", "assert failed", "Task watchdog got triggered",
                                        "Guru Meditation", "Backtrace:", "stack overflow", "Brownout" };
    static const char *const to[] = { "abort() called", "assertion failed", "task watchdog triggered",
                                      "guru meditation", "backtrace", "stack-overflow", "brownout" };
    for (char *c = s; *c; c++) {
        if (*c == '\n' || *c == '\r' || *c == '\t') *c = ' ';
    }
    for (size_t i = 0; i < sizeof from / sizeof from[0]; i++) {
        const size_t fl = strlen(from[i]), tl = strlen(to[i]);   /* tl <= fl: in place */
        for (char *hit = strstr(s, from[i]); hit; hit = strstr(hit + tl, from[i])) {
            memcpy(hit, to[i], tl);
            memmove(hit + tl, hit + fl, strlen(hit + fl) + 1);
        }
    }
}

void health_coredump_boot_report(void)
{
    const char *why;
    uint32_t word;
    s_size = (int32_t)probe(&why, &word);
    if (s_size == 0) {
        if (why) {
            ESP_LOGW(TAG, "coredump: partition holds no valid core dump (%s, size word 0x%08lx): clearing it",
                     why, (unsigned long)word);
            if (esp_core_dump_image_erase() != ESP_OK) ESP_LOGW(TAG, "coredump: clearing failed");
        }
        return;
    }

    esp_core_dump_summary_t *sum = calloc(1, sizeof *sum);
    char *reason = calloc(1, 200);
    if (!sum || !reason || esp_core_dump_get_summary(sum) != ESP_OK) {
        ESP_LOGW(TAG, "coredump: %ld bytes stored (summary unreadable); GET /coredump to fetch, DELETE /coredump to clear",
                 (long)s_size);
        free(sum);
        free(reason);
        return;
    }
    /* Backtrace as a plain list of PCs: idf.py monitor decodes every 0x4xxxxxxx address it sees, and
     * `xtensa-esp32s3-elf-addr2line -pfiaC -e build/pixelclip.elf <PCs>` takes the list as is. */
    char bt[16 * 11 + 1] = "";
    int n = 0;
    const uint32_t depth = sum->exc_bt_info.depth;
    for (uint32_t i = 0; i < depth && i < 16 && n < (int)sizeof bt; i++) {
        n += snprintf(bt + n, sizeof bt - n, "%s0x%08lx", i ? " " : "", (unsigned long)sum->exc_bt_info.bt[i]);
    }
    char epc[EPCx_REGISTER_COUNT * 18 + 1] = "";
    n = 0;
    for (int i = 0; i < EPCx_REGISTER_COUNT && n < (int)sizeof epc; i++) {
        if (sum->ex_info.epcx_reg_bits & (1u << i)) {
            n += snprintf(epc + n, sizeof epc - n, " epc%d 0x%08lx", i + 1, (unsigned long)sum->ex_info.epcx[i]);
        }
    }
    if (esp_core_dump_get_panic_reason(reason, 200) == ESP_OK) {
        defang(reason);
    } else {
        reason[0] = '\0';
    }
    char own[APP_ELF_SHA256_SZ];
    esp_app_get_elf_sha256(own, sizeof own);
    const char *dump_sha = (const char *)sum->app_elf_sha256;
    const bool same_app = strncmp(dump_sha, own, sizeof own - 1) == 0;

    ESP_LOGW(TAG, "coredump: task %s crashed at PC 0x%08lx, exccause %lu (%s) vaddr 0x%08lx,%s backtrace %s "
             "(depth %lu, corrupted %s)%s%s%s; %ld bytes, app elf %s (%s); GET /coredump to fetch, DELETE /coredump to clear",
             sum->exc_task[0] ? sum->exc_task : "?", (unsigned long)sum->exc_pc, (unsigned long)sum->ex_info.exc_cause,
             exccause_name(sum->ex_info.exc_cause), (unsigned long)sum->ex_info.exc_vaddr, epc, bt[0] ? bt : "-",
             (unsigned long)depth, sum->exc_bt_info.corrupted ? "yes" : "no",
             reason[0] ? ", reason \"" : "", reason, reason[0] ? "\"" : "",
             (long)s_size, dump_sha[0] ? dump_sha : "?",
             same_app ? "this firmware" : "OTHER firmware: decode with that build's pixelclip.elf");
    free(sum);
    free(reason);
}
