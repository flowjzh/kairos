#ifndef CSQLITE_SHIM_H
#define CSQLITE_SHIM_H
#include <sqlite3.h>

// SQLITE_TRANSIENT is a C macro ((sqlite3_destructor_type)-1) that Swift
// cannot import directly. Expose it as an inline function so bind_text/blob
// copy their arguments (the Swift String/Data may be freed right after).
static inline sqlite3_destructor_type kairos_sqlite_transient(void) {
    return (sqlite3_destructor_type)-1;
}

#endif
