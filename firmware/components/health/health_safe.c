/* health_safe.c — the safe-start rule (health_safe.h). Pure C, shared with the host test. */
#include "health_safe.h"

uint32_t health_safe_rule(uint32_t streak, const health_safe_in_t *in, bool *safe_start)
{
    const bool early_crash = in->crash && !in->radio_only && in->prev_known && in->prev_up_s < HEALTH_SAFE_START_WINDOW_S;
    *safe_start = false;
    if (!early_crash) return 0;
    if (streak + 1 >= HEALTH_SAFE_START_CRASHES) {
        *safe_start = true;
        return 0;
    }
    return streak + 1;
}
