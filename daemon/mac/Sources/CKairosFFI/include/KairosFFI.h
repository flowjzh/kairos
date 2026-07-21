#ifndef KAIROS_FFI_H
#define KAIROS_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The one C-ABI boundary to the Kairos Rust world (staticlib libkairos_ffi.a,
 * crate `ffi/`). Declarations accrete here by domain as more Rust modules are
 * surfaced; today: the dashboard report reducer.
 *
 * `segments` is a packed little-endian buffer of `count` records, each 32 bytes:
 *   [int64 activity_id][double start][double end][double seconds].
 * `activities_json` is a JSON object keyed by activity id (string) → activity
 * detail. Both entry points return a malloc'd NUL-terminated JSON string owned
 * by the caller (free via kairos_string_free), or NULL on malformed input. */

char *kairos_report_overview(const uint8_t *segments, size_t count,
                             const char *activities_json, double from, double to);

char *kairos_report_segments(const uint8_t *segments, size_t count,
                             const char *activities_json, size_t offset, size_t limit);

void kairos_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* KAIROS_FFI_H */
