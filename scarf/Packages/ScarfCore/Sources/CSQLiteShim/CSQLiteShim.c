#include "CSQLiteShim.h"

#if __has_include(<sqlite3.h>)

int scarf_sqlite3_disable_checkpoint_on_close(sqlite3 *db) {
    int enabled = 0;
    int rc = sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &enabled);
    if (rc != SQLITE_OK) return rc;
    return enabled == 1 ? SQLITE_OK : SQLITE_ERROR;
}

#endif
