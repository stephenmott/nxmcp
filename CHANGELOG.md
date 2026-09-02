# Changelog

Notable changes to nxmcp.

## [6.0.0.0] - 2026-08-30

Major version because concurrency and failure recovery now have an explicit execution and
retry contract. Several operations that could previously be replayed after a lost connection
are now deliberately no-retry.

### Added

* Added one process-wide, bounded execution gate around database-backed `tools/call` and
  `resources/read`. The manager-level decorator automatically covers every current and future
  tool/resource and shares the same gate across both capability types. Discovery methods,
  `initialize`, and `ping` remain ungated.
* Added `[Options] BusyTimeout=3000`, independent of the NexusDB operation `Timeout`. `0`
  fails fast; a negative value logs a warning and uses 3000 ms. Expiry returns protocol-shaped
  tool/resource error content rather than an unexplained JSON-RPC internal error.
* Added deterministic concurrency tests with event-controlled fake capability managers. They
  cover shared tool/resource exclusion, bounded waiting and release, discovery bypasses,
  both busy-result shapes, filter-before-gate ordering, exception-safe release, both NexusDB
  exception families, and cleanup after a retry itself fails.

### Changed

* NexusDB error classification now handles both `EnxDatabaseError` and `EnxBaseException`.
  Communication loss and illegal re-entry retire the session and may retry once only at an
  explicitly retry-enabled boundary. A general timeout is never retried: nxmcp best-effort
  calls `CancelProcessing`, tears down the complete component chain, and reconnects while the
  request still owns the execution gate.
* DDL/restructure, table maintenance, password changes, transactional execution, and switch
  state machines now use no-retry recovery. `batch_execute` distinguishes a confirmed
  rollback from rollback-by-session-retirement and unknown transaction state instead of
  unconditionally claiming success.
* Cleanup/reconnect errors no longer replace the original operation error returned to the
  caller. Switch rollback first retires a timeout/re-entered/lost session, then restores the
  previous target.

The production re-entry report and the key timeout/session-lock diagnosis came from Stephen
Mott in [PR #3](https://github.com/drpfau/nxmcp/pull/3). This release reimplements that fix at
the capability-manager boundary with bounded waiting and explicit replay policy instead of
merging the pull request's per-tool base-class change.

## [5.1.0.0] - 2026-08-02

### Changed

* **`explain_query` no longer executes the SELECT it explains.** NexusDB has no EXPLAIN,
  and the plan is only narrated into `TnxQuery.Log` while a statement runs — the log is
  written into the ExecStream of `StatementExecDirect` and never into the prepare stream.
  The engine's own answer is the statement option
  `#OPT::STATEMENT::NO_PROCESSING='1'`, which makes `TnxSqlRowBuilder.ReadSources` return
  immediately while `Optimize` — and with it the whole `#L+`/`#V+` narration — still runs.
  A read is therefore parsed, bound and optimized without a single row being read; the
  response reports `executed: false` and a note saying so. Row counts the optimizer only
  learns while reading are absent from such a plan.

  Writes are unchanged: no-processing mode rejects them (`UPDATE not supported in no
  processing mode`), so INSERT/UPDATE/DELETE and `SELECT ... INTO` still run inside a
  transaction that is always rolled back. DDL is still refused — it fits neither strategy.

* `StripSwitches` deliberately does **not** strip `#OPT::<group>::<name>='<value>'`.
  Unlike the other prefix switches its scope may be SESSION or DATABASE, i.e. state that
  outlives the statement. Leaving it in place means `AnalyzeSql` reports `skOther` and
  every tool that demands a SELECT rejects it, so it cannot be smuggled through a
  read-only tool. nxmcp emits `#OPT` itself only where it needs it, at statement scope.

### Added

* `DEPENDENCIES.md` — the library versions nxmcp is built against and the one patch a
  build needs. Now built against
  [Delphi-MCP-Server](https://github.com/GDKsoftware/Delphi-MCP-Server) `4e98e3b`
  (was `92bdbe9`), which fixes an access violation on unparseable JSON-RPC requests and
  invalid JSON in STDIO transport-level error replies. Note one behaviour change from
  that upgrade: unknown keys in a tool's `arguments` are now rejected with
  `Unknown parameter "x". Valid parameters: ...` instead of being ignored.

### Fixed

* Corrected the Win64 embedded build note: the SQL tokenizer's pointer truncation was
  fixed by NexusDB in 4.75, which uses the pointer-sized `TnxMemSize`. No patch is needed
  there or later — the previous note named a line and a code fragment that no longer
  exist.

## [5.0.0.0] - 2026-08-01

Major version because tool contracts are now enforced: input that earlier builds accepted
is rejected, and `explain_query` no longer persists the statement it explains.

### Security

Tools that promise to read, or to act on one named table, could be made to do neither.
Reported by a user embedding nxmcp in their own product; all four vectors were reproduced
against a live server before fixing. Anyone running an earlier build should update.

* **`execute_query` executed arbitrary statements.** Validation was
  `StripSwitches(sql).ToUpper.StartsWith('SELECT')`, and NexusDB executes a
  semicolon-separated batch submitted as one `SQL.Text` in a single call. So
  `SELECT * FROM t; DELETE FROM t` returned a normal-looking result set *and* emptied the
  table. `SELECT * INTO t2 FROM t1` also passed, and creates and populates a table.
* **`explain_query` validated nothing at all** and called `Open`, so a bare
  `DELETE FROM t` executed. This was the widest hole - no semicolon trick needed.
* **`get_table_data` / `get_table_schema` concatenated the table name** into SQL inside
  double quotes with no validation, so a name containing `"` closed the quote and appended
  a second statement.
* **`insert_record` / `update_records` / `delete_records` / `drop_index`** concatenated
  table, column and index names (and, for the record tools, JSON keys) the same way.

Fixes, in `nxmcp.SqlUtils.pas`:

* `AnalyzeSql` classifies a statement using **NexusDB's own SQL lexer**
  (`TnxSQLTokenizer`, `nxSQLTok.pas`) rather than scanning text. Comments, string literals
  and quoted identifiers are distinct token types, so none of them can hide a `;` or an
  `INTO`, and a column legitimately named `"into"` is not a false positive. Anything the
  lexer cannot tokenize fails closed.
* `CheckTableName` / `CheckIdentifier` validate against the engine's own
  `nxCheckValidTableName` / `nxCheckValidIdent`. Their character set (`nxcValidIdentChars`,
  `nxllConst.pas`) excludes `"` and `;`. Validation rather than escaping is not a
  shortcut - NexusDB has no escape for a quote inside a quoted identifier at all
  (`SELECT 1 AS "a""b"` is a syntax error), so there is nothing to escape to. Meta tables,
  memory/temp tables (`<name>`), child tables (`parent:child`) and names with spaces all
  still work.
* `update_records` / `delete_records` validate the **composed** statement, not the WHERE
  fragment, which keeps subselects working (`WHERE id IN (SELECT ...)`) while rejecting
  `1=1; DROP TABLE other`.

`explain_query` now accepts one SELECT/INSERT/UPDATE/DELETE - including `SELECT ... INTO`,
which is worth profiling - and rejects DDL. It still executes the statement, because
NexusDB has no non-executing explain: `TnxQuery.Log` is filled from the execution round
trip and `Prepare` alone leaves it empty (verified). Writes are therefore run inside a
transaction that is **always rolled back**, and the response reports `executed` and
`rolledBack`.

Two details that only show up at the edges:

* Once the transaction is open, a lost connection is **not** retried.
  `ExecuteWithReconnect` reconnects before retrying, which discards the transaction, so the
  second attempt would run the write outside one and commit it - while `InTransaction` was
  then false and the rollback was skipped, reporting `rolledBack: true` for a write that
  had persisted. The transactional path now uses a plain `Open`; a dropped connection
  fails, and the server rolls back on disconnect. Same reasoning `batch_execute` already
  applies to its own transaction.
* For `SELECT ... INTO` the rollback undoes the copied rows but **not** the table, because
  creating one is not transactional (verified: the target is left behind, empty). Rather
  than claim a clean rollback, the response carries a `note` saying so and pointing at
  `drop_table`. DDL is rejected outright for the same reason.

`execute_sql` and `batch_execute` are unchanged and remain deliberately unrestricted.

### Added

* **Per-tool and per-resource availability.** New `[Tools]` and `[Resources]` sections in
  `nxmcp.ini`: an entry set to `0` is neither listed nor callable, so the client never sees
  it. **Everything is on by default** - only an explicit `0` switches something off, so an
  absent entry, an existing ini, or a tool added by a later version all just work. A freshly
  generated ini lists every registered tool and resource set to `1`, enumerated from
  `TMCPRegistry` rather than a hard-coded table, so new tools appear automatically.

  Enforcement lives in `nxmcp.CapabilityFilter.pas`, which wraps the library's managers
  rather than patching them: the MCP library builds its tool table once in the manager
  constructor from a registry that has no unregister. The wrapper refuses `tools/call` /
  `resources/read` **by name**, before the inner manager sees it - that layer does not
  depend on any response shape - and strips disabled entries from the list responses on top.
  If a list response ever stops matching the expected shape the filter raises rather than
  passing the full list through, and the by-name refusal still holds.

### Changed

* README gained a Security section documenting each tool's contract, how it is enforced,
  and the recommendation to use a rights-restricted NexusDB user when embedding nxmcp in a
  product rather than using it as a dev tool.

## [4.1.0.0] - 2026-08-01

### Added

* **`close_inactive_tables`** (Table Maintenance) — releases the tables *and* folders the
  NexusDB server holds open in its cache for this session
  (`TnxSession.CloseInactiveTables` followed by `CloseInactiveFolders`). Frees server-side
  file handles before backing up, copying or replacing database files. In embedded mode the
  handles released are held by the nxmcp process itself. Takes no parameters.
* **`list_locks`** (Utility) — live lock state from the server's lock meta tables:
  `#TABLE_LOCKS` (record and cursor level) and `#TRANSACTION_LOCKS` (transaction level).
  Parameters: `lockType` (`table` / `transaction` / `all`, default `all`), `tableName`
  filter, `maxRows` (default 500, max 10000).

  Both meta tables only exist on newer NexusDB releases. Instead of failing there,
  `list_locks` returns `"available": false` with an explanation for that lock table. The
  check asks the server — it reads `SELECT METATABLE_NAME FROM #META`, which enumerates the
  meta tables the SQL engine that ran the query actually implements. In remote mode that
  engine lives in `nxServer.exe`, whose version is independent of this client, so a
  client-side check against nxmcp's own constants would be wrong. Any other failure
  (permissions, lost connection) is still raised.

### Required dependency patch — dataset-serialize

**`list_locks` needs a one-line patch in dataset-serialize that is not yet fixed upstream.**
Without it the tool fails whenever locks actually exist.

`TDataSetSerialize.DataSetToJSONObject` in `src/DataSet.Serialize.Export.pas` groups
`ftLongWord` with the plain integer types and reads it via `AsInteger`. Delphi's
`TLongWordField.GetAsInteger` (`Data.DB`) calls `RangeError(Value, 0, High(Integer))` for
values above 2147483647, so serializing such a column raises. `ftLongWord` is the only type
in that case group whose range does not fit in `Integer`.

The lock meta tables expose `SESSION_ID`, `TRANSACTION_CONTEXT_ID`, `DATABASE_ID` and
`CURSOR_ID` as `Word32`, and real session ids routinely exceed the limit (observed here:
4273865552). The same failure affects `execute_query`, `get_table_data` and `batch_execute`
on any table with a large `Word32` value, so this is not specific to the new tool.

Give `ftLongWord` its own branch reading `AsLargeInt` — `Int64` represents the whole
unsigned 32-bit range exactly, so the value stays a JSON number:

```diff
-      TFieldType.ftInteger, TFieldType.ftSmallint, TFieldType.ftAutoInc{$IF NOT DEFINED(FPC)}, TFieldType.ftShortint, TFieldType.ftLongWord, TFieldType.ftWord, TFieldType.ftByte{$ENDIF}:
+      TFieldType.ftInteger, TFieldType.ftSmallint, TFieldType.ftAutoInc{$IF NOT DEFINED(FPC)}, TFieldType.ftShortint, TFieldType.ftWord, TFieldType.ftByte{$ENDIF}:
         Result.{$IF DEFINED(FPC)}Add{$ELSE}AddPair{$ENDIF}(LKey, {$IF DEFINED(FPC)}LField.AsInteger{$ELSE}TJSONNumber.Create(LField.AsInteger){$ENDIF});
+      {$IF NOT DEFINED(FPC)}
+      TFieldType.ftLongWord:
+        Result.AddPair(LKey, TJSONNumber.Create(LField.AsLargeInt));
+      {$ENDIF}
       TFieldType.ftLargeint:
```

Reported upstream as
[viniciussanchez/dataset-serialize#269](https://github.com/viniciussanchez/dataset-serialize/issues/269).
Present in `master` and in releases v.2.7.0 and v.2.6.9. Remove this note once a released
version carries the fix.
