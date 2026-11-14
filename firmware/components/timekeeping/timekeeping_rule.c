/* timekeeping_rule.c — the pure boot-time clock decision (timekeeping_rule.h). No ESP-IDF, no float, no heap. */
#include "timekeeping_rule.h"

#include <string.h>

const char *timekeeping_how_str(tk_how_t how)
{
    return how == TK_HOW_RTC ? "rtc" : how == TK_HOW_ANCHOR ? "anchor" : "none";
}

void timekeeping_rule_boot(const tk_boot_in_t *in, tk_boot_out_t *out)
{
    memset(out, 0, sizeof *out);
    out->anchor_age_s = -1;
    const bool anchor_ok = in->anchor >= TK_RULE_EPOCH_MIN && in->anchor < TK_RULE_EPOCH_MAX;
    /* the RTC plausibly continued from the anchor (it may sit up to one anchor period before it) */
    const bool rtc_plausible = anchor_ok && in->sys_now >= in->anchor - TK_RULE_ANCHOR_SLACK_S &&
                               in->sys_now <= in->anchor + TK_RULE_ANCHOR_MAX_GAP_S;
    bool continuity = false;
    switch (in->rst) {
    case TK_RST_KEEPS: continuity = true; break;
    case TK_RST_KEEPS_EXT: continuity = in->keep_more; break;
    case TK_RST_DEEPSLEEP:
        /* the anchor was saved at sleep entry: RTC now - anchor is the sleep */
        continuity = in->keep_more && rtc_plausible && in->sys_now - in->anchor < TK_RULE_DEEPSLEEP_TRUST_S;
        break;
    case TK_RST_LOST:
    default: continuity = false; break;
    }
    out->trusted = in->trusted_nvs && continuity;
    if (out->trusted) {
        out->how = TK_HOW_RTC;
        return;
    }
    if (anchor_ok) {
        out->from_anchor = true;
        if (rtc_plausible) {
            out->how = TK_HOW_RTC;   /* deep-sleep wake, core reset: it includes the time spent asleep */
            const int64_t age = in->sys_now - in->anchor;
            out->anchor_age_s = age > 0 ? age : 0;
        } else {
            /* after a power-on the RTC restarted near 0: assume ~0 s off, anchor + uptime; the run is broken */
            out->how = TK_HOW_ANCHOR;
            out->set_clock = true;
            out->set_epoch_s = in->anchor + in->uptime_us / 1000000;
            out->set_usec = in->uptime_us % 1000000;
            out->new_run = true;
            out->anchor_age_s = in->uptime_us / 1000000;
        }
        return;
    }
    /* no clock at all: a lost RTC still starts a new run (nothing of the old one carries over) */
    out->how = TK_HOW_NONE;
    out->new_run = in->rst == TK_RST_LOST;
}
