#ifndef CSQLITESHIM_H
#define CSQLITESHIM_H

#if __has_include(<sqlite3.h>)
#include <sqlite3.h>

/// Non-variadic wrapper around `sqlite3_db_config(db,
/// SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &out)`. Swift cannot call C
/// variadic functions, so `sqlite3_db_config` is unavailable to
/// `LocalSQLiteBackend` directly.
///
/// Returns `SQLITE_OK` only when SQLite reports the flag as ON after the
/// call; any other result means the connection WILL checkpoint the WAL
/// into the main database file when it is the last one to close.
int scarf_sqlite3_disable_checkpoint_on_close(sqlite3 *db);

#endif

#endif /* CSQLITESHIM_H */
