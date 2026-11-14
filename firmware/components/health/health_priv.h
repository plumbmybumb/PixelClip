/* health_priv.h — internal to components/health. */
#pragma once

/* coredump.c: log the stored core dump's summary (every boot while one is stored); called by
 * health_boot_record(). Clears an invalid image (blank-check failure, bad checksum) with a warning. */
void health_coredump_boot_report(void);
