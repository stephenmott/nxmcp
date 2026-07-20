# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**nxmcp** is an MCP (Model Context Protocol) server for NexusDB NXserver. This project enables AI assistants to interact with NexusDB databases through the standardized MCP protocol. The server is written in Delphi and uses NexusDB components to connect to the database.

## Repository Structure

- `Source/` - Main source code
  - `nxmcp.dpr` - Main program
  - `dmnx.pas` - NexusDB connection DataModule (auto-creates `nxmcp.ini` on first run)
  - `nxmcp.Resource.*.pas` - MCP resource implementations
  - `nxmcp.Tool.*.pas` - MCP tool implementations
- `sample code/` - Reference code for NexusDB and MCP development
  - `sample code\Delphi-MCP-Server-Reference` - MCP Library (reference only)
  - `sample code\NexusDB` - NexusDB examples
  - `sample code\dataset.serialize` - JSON serialization library

## Development Workflow

**Important:** The user must manually compile and run the Delphi project. Claude cannot execute the compiler or run the executable directly.

- Ask the user to compile and run
- Once running, Claude can interact with the MCP HTTP API via curl
- Default endpoint: `http://localhost:3000/mcp`

## MCP Resources

| Resource URI | Description |
|--------------|-------------|
| `nexusdb://server` | Connection status and server info |
| `nexusdb://tables` | List of all tables in the database |
| `nexusdb://schema` | Schema overview (tables with record counts) |

## MCP Tools

### Query & Discovery (Phase 2)
| Tool | Description |
|------|-------------|
| `execute_query` | Execute SELECT queries, returns JSON results (supports `:name` parameters via `params`) |
| `get_table_schema` | Get detailed schema for a specific table |

### Data Manipulation (Phase 3)
| Tool | Description |
|------|-------------|
| `execute_sql` | Execute INSERT/UPDATE/DELETE statements (supports `:name` parameters via `params`) |
| `get_table_data` | Paginated table data retrieval |
| `insert_record` | Insert record with JSON data |
| `update_records` | Update records matching WHERE clause |
| `delete_records` | Delete records matching WHERE clause |

### Schema Management (Phase 4)
| Tool | Description |
|------|-------------|
| `create_table` | Create new table with column definitions |
| `drop_table` | Delete a table |
| `copy_table` | Clone table structure (optionally with data) |
| `rename_table` | Rename a table |
| `add_column` | Add column with optional default value |
| `drop_column` | Remove column from table |
| `modify_column` | Change column type, size, or rename |
| `create_index` | Create index on column(s) |
| `drop_index` | Remove an index |

### Schema Metadata (Phase 4b)
| Tool | Description |
|------|-------------|
| `set_table_description` | Set or clear the description (comment) on a table |
| `set_column_description` | Set or clear the description on a column |
| `set_index_description` | Set or clear the description on an index |
| `set_field_validator` | Add/remove MinMax or NoChange server-side validator on a column |
| `set_column_default` | Add/replace/clear default value on an existing column (CurrentDateTime, CurrentUser, Constant) |
| `set_data_policies` | Set/clear table-level data policies: deny insert/modify/delete, min/max record count |
| `set_audit` | Enable/disable audit-trail logging and BLOB inclusion for a table |

`get_table_schema` reads the table dictionary directly and surfaces table description, column descriptions, defaults, validators, index descriptions, data policies, audit settings, and (read-only) referential-integrity references. `list_indexes` also includes each index's description.

### Table Maintenance (Phase 5)
| Tool | Description |
|------|-------------|
| `empty_table` | Delete all records from a table (keeps structure) |
| `pack_table` | Compact table to reclaim deleted space |
| `reindex_table` | Rebuild an index |
| `recover_table` | Attempt to recover records from broken table |
| `change_password` | Change table password |
| `get_autoinc_value` | Get next auto-increment value |

### Transactions (Phase 6)
| Tool | Description |
|------|-------------|
| `batch_execute` | Execute multiple SQL statements in a single transaction |

### Utility (Phase 7)
| Tool | Description |
|------|-------------|
| `list_tables` | List all user tables in the connected database |
| `count_records` | Get record count using table metadata (fast, no scan) |
| `list_indexes` | List all indexes on a table with their fields |
| `explain_query` | Show query execution plan (standard or verbose mode) |

### Database Management (Phase 8)
| Tool | Description |
|------|-------------|
| `list_aliases` | List available database aliases on the server (reports `currentAlias`/`currentAliasPath`) |
| `switch_database` | Switch the active database by `aliasName` **or** `aliasPath` (keeps session) |
| `switch_server` | Switch server connection (full reconnect): `mode` remote/embedded; optional `aliasName`/`aliasPath` |

### Logging
`[Options] LogToFile` (default off) enables file logging; `[Options] LogFileName` overrides the path. **Leave `LogFileName` empty**: `Tnxmodule.ConfigureLogging` then derives `<exe name>.<pid>.log`, one file per process.

File logging is implemented in `nxmcp.FileLog.pas`, **not** by `TLogger.LogToFile` — `ConfigureLogging` explicitly sets `TLogger.LogToFile := False` and hooks `TLogger.OnLogMessage` instead. Do not turn `TLogger.LogToFile` back on. The library's `EnsureLogFile` opens the log through `TStreamWriter.Create(FileName, ...)`, which passes no share bits (exclusive handle) and lets an open failure escape as an exception. Under the STDIO transport *every MCP client spawns its own `nxmcp.exe`* — Claude Code and Claude Desktop routinely run concurrently — so the second instance could not open the shared log and died before its transport started, which the client reports as "MCP server exited immediately".

`nxmcp.FileLog` instead opens `fmShareDenyWrite` (editors and `tail` can read the log while nxmcp holds it), appends, and is fail-soft: an unopenable or unwritable log emits a `[WARN ] File logging disabled` line on **stderr** (never stdout, which carries JSON-RPC) and the server continues console-only. Setting an explicit `LogFileName` shared by two concurrent instances is therefore safe but pointless — the loser silently drops to console-only.

### Connection Recovery: EnsureConnection vs EnsureSession vs ExecuteWithReconnect
`nxSession1.Active` and `nxDatabase1.Connected` are **client-side flags**: after the server dies or the socket drops they both still report `True`, and only the next server round-trip reveals the truth. Recovery therefore needs two mechanisms, and most tools use both.

| Helper | Guarantees | Use when |
|--------|-----------|----------|
| `EnsureConnection` | session **and** database open (`Reconnect` = `ForceDisconnect` + `Connect`) | the tool needs the *current* database — the 36 data/schema tools |
| `EnsureSession` | session/transport/engine only, **database left closed** | the tool is server-level and must survive a database that won't open: `list_aliases`, `switch_database` |
| `ExecuteWithReconnect` | catches `DBIERR_SERVERCOMMLOST` (`$2C0C`), reconnects, retries the action **once** | wraps the actual round-trip; the only way to detect a stale-but-`Active` handle |

Rules:
- **Never call `EnsureConnection`/`EnsureSession` in `switch_server` or `SwitchToEmbedded`.** The server being switched away from is frequently the one that is down — that is *why* the caller is switching. Requiring the old connection to be healthy turns the escape hatch into a deadlock.
- **A teardown must never abort on its first failing step.** `Disconnect` and `ForceDisconnect` both run `TearDownComponents`, which wraps every `Close` / `Active := False` in its own `try..except`, so all eight components end up inactive even when the socket is dead. The two differ *only* in whether the first error is recorded in `GLastError` or discarded. Closing a dataset, database or session is a server round-trip and raises on a dead connection; a single-`try` sequence would skip the engines and leave the transport active (which then silently reuses a dead transport on the next `Connect`).
- **Mode-changing** switches tear down via `DisconnectForSwitch`, which guards `ReleaseDatasets` (its `nxSession1.CloseInactiveTables` is a server round-trip) and then calls `Disconnect`. An **embedded→embedded** `SwitchToEmbedded` never tears the engine down — it delegates to `SwitchDatabaseTarget` (database-level close/reopen; session, server engine and SQL engine stay up). `SwitchDatabaseTarget` uses `CloseDatabaseForSwitch`, which falls back to `ForceDisconnect` so that `OpenTargetDatabase` rebuilds the whole chain.
- `OpenTargetDatabase` reopens on the new target, falling back to a full `Connect` when the preceding teardown had to force-disconnect.
- In the `except` block of any switch, hold the failure message in a **local** before rolling back: `Connect` resets `GLastError` to `''` on entry, so a successful rollback silently erased the original error (this surfaced as `Error executing tool:` with an empty message).
- **Embedded targets are validated before anything closes.** The embedded engine opens a directory in *this* process, so `SwitchToEmbedded`, `SwitchDatabaseTarget` (embedded mode) and `ConnectEmbedded` all reject a non-existent path with `Embedded database path does not exist: ...` while the current connection is still fully intact. Remote alias paths are server-side and cannot be pre-checked.
- **Fatal engine state is surfaced, never reset.** Once NexusDB records a critical failure (e.g. an AV inside engine code) the process-wide `nxllException._FatalException` flag makes every engine call fail with "operations are suspended until the server is restarted", and nothing short of a process restart clears it — for embedded mode "the server" *is* nxmcp.exe. `dmnx.WithFatalHint` appends a restart hint to connect/switch errors when the flag is set. Do not try to reset the flag; it exists to protect data files.

### Server Mode: Remote vs Embedded
The `[Connection] Mode` ini key (or `switch_server`'s `mode` param) selects how `nxSession1` reaches a server:
- **Remote** (default) — `nxSession1.ServerEngine = nxRemoteServerEngine1` over `nxWinsockTransport1` (a separate NXserver process). Supports `AliasName` or `AliasPath`.
- **Embedded** — `nxSession1.ServerEngine = nxServerEngine1`, an in-process `TnxServerEngine` with `nxSqlEngine1` (`TnxSqlEngine`, wired in `dmnx.dfm` via `SqlEngine = nxSqlEngine1`) and the storage sub-engines from `uses nxseAllEngines`. **Embedded has no aliases — `AliasPath` only, and it is required.**

`Connect` branches to `ConnectRemote`/`ConnectEmbedded`; `Disconnect`/`ForceDisconnect` deactivate *both* engines so the components not in use are always `Active := False`. `WireServerEngine` (re)points the session at the mode's engine (session must be closed). Runtime switch: `switch_server mode="embedded" aliasPath=...` → `dmnx.SwitchToEmbedded`; `mode="remote" ...` → `dmnx.SwitchServer` (a mode change does a full reconnect with rollback and sets `FServerMode`; embedded→embedded only switches the database, see the rules above). `switch_database` by `aliasName` is rejected while embedded (path only). `IsEmbedded`/`ServerMode` expose the state; `Tnxmodule.ModeToStr`/`StrToMode` parse `Remote`/`Embedded`.

> **Win64 build note (embedded SQL):** NexusDB's SQL tokenizer had a 64-bit pointer-truncation bug at `nxSQLTok.pas:1235` (`EndPtr := PWideChar(DWord(CurPtr) + ...)` — `DWord` is 32-bit). It only bites the **in-process** engine on Win64 (remote tokenizes in the 32-bit `nxServer.exe`), yielding `Invalid token: error at line 1 pos 1` for every embedded query. Fixed to `NativeUInt(CurPtr)`. Anyone rebuilding embedded on Win64 needs this fix in the NexusDB source.

> **Stale-library build note (embedded switch AV):** a July 2026 beta build crashed with `Access violation ... Read of address 0000000000000010` on the *second* embedded engine activation in one process (`switch_server mode="embedded"`, any target path), after which the exception hook set `_FatalException` and every call failed with "suspended until the server is restarted". The crash is a NexusDB library bug in pre-2026-07-09 `nexusdb4` sources; it is not reproducible when built against the library from 2026-07-13 or later (verified by driving `dmnx.pas` through the exact scenario, cross-thread, valid and invalid paths). If that signature ever reappears, first check which library revision the exe was built against — and note nxmcp now avoids the engine bounce entirely for embedded→embedded switches anyway.

**AliasName vs AliasPath:** `TnxDatabase` exposes two mutually-exclusive ways to point at a database — `AliasName` (a server-configured alias) and `AliasPath` (a server-side filesystem path to the database folder). Setting one clears the other on the component, and both require the DB to be closed first (the switch/reconnect logic already handles this). The `.ini` `[Database]` section accepts either `AliasName` or `AliasPath` (path wins if both are set). `switch_database`/`switch_server` accept either `aliasName` or `aliasPath` (never both). The DataModule tracks the active target in `FAliasName`/`FAliasPath` (exactly one non-empty); `dmnx.SwitchDatabaseTarget` is the shared core with name/path-aware rollback, wrapped by `SwitchDatabase` and `SwitchDatabaseByPath`.

**batch_execute usage:**
```json
{
  "statements": ["SELECT * FROM Orders", "SELECT * FROM Inventory"],
  "snapshot": true
}
```
- Supports SELECT, INSERT, UPDATE, DELETE
- All statements succeed together or all are rolled back
- `snapshot`: Use snapshot transaction for consistent point-in-time reads (default: false)
- SELECT results include `data` array; non-SELECT results include `rowsAffected`

### Query Parameters (execute_query / execute_sql)
Both tools accept an optional `params` argument — a JSON array (passed as a string, like all complex tool arguments) binding values to `:name` placeholders in the SQL:

```json
{
  "sql": "SELECT * FROM Orders WHERE CustomerGuid = :cust AND OrderDate >= :since AND Total > :min",
  "params": "[{\"name\":\"cust\",\"value\":\"d94660ff-...\",\"type\":\"guid\"},{\"name\":\"since\",\"value\":\"2024-01-15\",\"type\":\"date\"},{\"name\":\"min\",\"value\":100}]"
}
```

- Entries are `{"name", "value", "type"?}`. `type` is inferred from the JSON value when omitted (integral number → integer, fractional → float, bool → boolean, string → string); explicit types: `string`, `memo`, `integer`, `float`, `currency`, `boolean`, `date`, `time`, `datetime`/`timestamp`, `guid`, `blob` (base64). `"value": null` (or omitting `value`) binds a typed NULL.
- Values are bound as **native typed TParams** (`nxmcp.QueryParams.pas` → `ApplyJsonParamsToQuery`), not spliced into the SQL — no quoting/escaping, and **no typed-literal syntax needed** for GUID/DATE/TIME/DATETIME columns (this is the easiest way to compare against those columns; see "Typed-literal columns" below for the raw-SQL rules). Same lenient input as `insert_record` (bare/braced GUIDs any case; `T` or space separators; trailing `Z`/offset stripped). Date/time strings are converted to `TDateTime` client-side, so binding is locale-independent.
- NexusDB parses `:name` per **occurrence** (`quParseSql` creates one TParam each, all replaced positionally with `?`); a repeated name is bound to every occurrence. `:"multi word"` names are supported; `::` and colons inside quotes/comments are not parameters.
- Both tools call `nxQuery1.Params.Clear` before setting `SQL.Text`: `TnxQuery.quSqlChanged` carries old values onto same-named params of the next statement (`TParams.AssignValues`), which would let a stale binding from a previous tool call silently satisfy the missing-parameter check.
- Client-side validation errors (before the server round-trip): missing values for placeholders, names not in the SQL (lists what is), unknown `type`, unknown entry keys (catches `"vaule"` typos), fractional value with type `integer`, invalid GUID/date/time/base64.
- `explain_query` and `batch_execute` do **not** take params.

## NexusDB-Specific Notes

### SQL Syntax Differences
- DROP INDEX: `DROP INDEX "tablename"."indexname"` (not `ON` syntax)
- RENAME TABLE: `ALTER TABLE "old" RENAME TO "new" RESTRICT`
- System tables: `#TABLES`, `#FIELDS`, `#INDEXES` (column names have underscores like `TABLE_NAME`)

### Typed-literal columns: GUID / Date / Time / DateTime (string literals rejected)
NexusDB does **not** coerce a plain string literal (`'...'`) into a GUID, DATE, TIME or DATETIME column — assigning or comparing one raises `Type mismatch ... (column: X, [GUID/DATE/...])`. Each requires its typed literal, in a **fixed format** (parsed by `StringToGUID` and `nxsdDateTimeParser.pas`, which are strict about position/length):

| Column type | Typed literal | Format notes |
|---|---|---|
| GUID | `GUID '{...}'` | **Braces required** (`{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`); stored/returned braced + uppercase |
| Date | `DATE 'YYYY-MM-DD'` | exactly 10 chars |
| Time | `TIME 'HH:MM:SS'` or `'HH:MM:SS.fff'` | len 8 or 12 |
| DateTime | `TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.fff]'` | **space** between date and time, **not** `T`; no timezone offset |

```sql
-- WRONG (type mismatch):  SET "DT" = '2024-01-15 13:45:00'   /  SET "DT" = TIMESTAMP '2024-01-15T13:45:00'
-- RIGHT:                  SET "DT" = TIMESTAMP '2024-01-15 13:45:00'
```
Watch out for round-trips: `get_table_data`/`execute_query` return DateTime as ISO 8601 **with `T` and a local offset** (e.g. `2024-01-15T13:45:00.000+01:00`, per the `dataset.serialize` export config in `dmnx.pas`), which is **not** directly writable — the `T` and offset must be removed.

`insert_record` / `update_records` handle all of this automatically: they read the table's column types (`nxmcp.ValueFormat.pas` → `GetTableFieldTypes`) and emit the correct typed literal, normalizing the incoming JSON string via `FormatJsonValueAsSql` (`NormalizeGuidLiteral` / `NormalizeDateLiteral` / `NormalizeTimeLiteral` / `NormalizeTimestampLiteral`). They accept lenient input — bare or braced GUIDs (any case), and dates/times with `T` or space separators and a trailing `Z`/offset (stripped, wall-clock preserved) — and reject genuinely invalid values with a clear client-side message. The **WHERE clause** of `update_records` and the raw `batch_execute` SQL are passthrough — there you must write the typed literal yourself. In `execute_query`/`execute_sql`, prefer a `:name` parameter with `type` guid/date/time/datetime (see "Query Parameters" above) — typed binding sidesteps the literal syntax entirely.

### Schema Operations
- Use `TnxDataDictionary` for schema manipulation (faster than SQL)
- Restructure via `database.RestructureTableEx()` with `TnxTableMapperDescriptor`
- Table passwords: Use `SET PASSWORDS ADD 'password'` after connection

### Field Types
Supported types for create_table/add_column:
`AutoInc`, `ShortString`, `WideString`, `Integer`, `Int64`, `Word`, `Byte`, `Boolean`, `Float`, `Currency`, `DateTime`, `Date`, `Time`, `Blob`, `Memo`

### Column Options on create_table / add_column / modify_column
`create_table` columns accept per-column `required` (NOT NULL), `description`, and a `default` object (`{type, constantValue?, applyAt?, applyOnInsert?, applyOnModify?, overwriteNonNull?}`); plus a table-level `description`. `add_column` accepts `required`, `description`, `defaultValueType` (incl. `Constant` via `constantValue`), `applyAt`, `applyOnModify`, `overwriteNonNull`. `modify_column` accepts `required` as a tri-state string (`"true"`/`"false"`/empty = unchanged). Shared logic lives in `nxmcp.ColumnSpec.pas` (`SetFieldDefault`, `ApplyColumnMetadataFromJSON`). NOTE: `fdRequired` is set directly, then reconciled with `FieldsDescriptor.UpdateSetupAndOffsets` (the EnterpriseManager restructure pattern).

### Default Value Types
For add_column/create_table: `CurrentDateTime`, `CurrentUser`, `Constant`

### Statement Switches
Prefix SQL with switches to control execution:
| Switch | Syntax | Purpose |
|--------|--------|---------|
| `#B` | `#B+` / `#B-` | BLOB copying (default `-`: link only) |
| `#I` | `#I+` / `#I-` | Index optimization (default `+`: on) |
| `#S` | `#S+` / `#S-` | Query simplification (default `+`: on) |
| `#L` | `#L+` / `#L-` | Query logging: plan summary, index used, join strategy |
| `#V` | `#V+` / `#V-` | Verbose logging: full optimizer decisions, all indexes considered, relation analysis |
| `#T` | `#T 5000` | Timeout in milliseconds |

```pascal
// Example: Get execution plan
nxQuery1.SQL.Text := '#L+ SELECT * FROM Orders WHERE Status = ''Active''';
nxQuery1.Prepare;
// nxQuery1.Log now contains execution plan

// Example: Disable index optimization for testing
nxQuery1.SQL.Text := '#I- SELECT * FROM LargeTable WHERE ID > 100';
```

### Transaction API
NexusDB transactions are managed via `TnxDatabase`:
```pascal
nxDatabase1.StartTransaction(Snapshot);  // Begin (snapshot=true for read consistency)
nxDatabase1.TryStartTransaction(Snapshot); // Returns false if already in transaction
nxDatabase1.Commit;    // Commit (manual rollback needed on error)
nxDatabase1.Rollback;  // Rollback all changes
nxDatabase1.InTransaction;  // Check if in transaction (property)
```

## Key Units

- `nxsdDataDictionary` - Schema manipulation
- `nxsdTypes` - Field types (TnxFieldType)
- `nxsdTableMapperDescriptor` - Restructure mapping
- `nxsdServerEngine` - Task info types (TnxTaskStatus, TnxAbstractTaskInfo)
- `nxllException` - nxCheck error handling

## Error Handling Patterns

### Ex Methods Return Error Codes
Methods ending in `Ex` return `TnxResult` instead of raising exceptions.

**Synchronous methods:**
| Method | Ex Variant | Notes |
|--------|------------|-------|
| `CreateTable` | `CreateTableEx` | Create new table |
| `GetDataDictionary` | `GetDataDictionaryEx` | Get table schema |
| `ChangePassword` | `ChangePasswordEx` | Change table password |
| `DeleteTable` | - | No Ex variant (raises exception) |
| `EmptyTable` | - | No Ex variant (raises exception) |
| `RenameTable` | - | No Ex variant (raises exception) |

**Async methods (return TnxAbstractTaskInfo):**
| Method | Ex Variant | Notes |
|--------|------------|-------|
| `RestructureTable` | `RestructureTableEx` | Modify table structure |
| `PackTable` | `PackTableEx` | Compact table, reclaim space |
| `ReIndexTable` | `ReIndexTableEx` | Rebuild index |
| `RecoverTable` | `RecoverTableEx` | Recover broken table |

**Other methods returning TnxResult:**
- `AddFieldToTable()` - simpler alternative to restructure for adding fields

**Always wrap `*Ex` methods with `nxCheck()`:**
```pascal
uses nxllException;

// Wrong - ignores error
nxmodule.nxDatabase1.GetDataDictionaryEx(TableName, Password, Dict);

// Correct - raises exception on error
nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(TableName, Password, Dict));
```

### Async Task Error Handling
For async operations like `RestructureTableEx`, check errors at TWO points:

1. **Immediate** - the method return value (e.g., table locked)
2. **After completion** - `TnxTaskStatus.tsErrorCode` (e.g., processing errors)

```pascal
// 1. Check immediate error
nxCheck(nxmodule.nxDatabase1.RestructureTableEx(TableName, Password,
  NewDict, Mapper, LTaskInfo));

// 2. Wait for completion and check task status
if Assigned(LTaskInfo) then
try
  while True do
  begin
    LTaskInfo.GetStatus(LCompleted, LTaskStatus);
    if LCompleted then
      Break;
    Sleep(100);  // Avoid busy-waiting
  end;
  nxCheck(LTaskStatus.tsErrorCode);  // Check async error
finally
  LTaskInfo.Free;
end;
```

### TnxTaskStatus Fields
```pascal
TnxTaskStatus = packed record
  tsStartTime    : TnxWord32;    // Start tick count
  tsSnapshotTime : TnxWord32;    // Current tick count
  tsTotalRecs    : TnxWord32;    // Total records to process
  tsRecsRead     : TnxWord32;    // Records read
  tsRecsWritten  : TnxWord32;    // Records written
  tsErrorCode    : TnxResult;    // Error code (check with nxCheck)
  tsPercentDone  : Byte;         // Progress percentage
  tsFinished     : Boolean;      // Completion flag
  tsErrorMessage : string;       // Human-readable error message
end;
```
