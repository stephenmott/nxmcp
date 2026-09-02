# nxmcp - NexusDB MCP Server

An MCP (Model Context Protocol) server that enables AI assistants to interact with NexusDB databases. Built with Delphi, this server exposes NexusDB operations as MCP tools and resources.

## Features

* **Dual Transport** - HTTP and STDIO (for Claude Desktop and other MCP clients)
* **Safe Shared Access** - Concurrent HTTP callers are serialized with a bounded wait, and timed-out NexusDB sessions are replaced before the next request
* **Query Execution** - Run SELECT queries and retrieve results as JSON
* **Data Manipulation** - Insert, update, and delete records
* **Schema Management** - Create tables, add columns, manage indexes
* **Schema Metadata** - Descriptions on tables/columns/indexes, field validators, defaults on existing columns, data policies, audit settings
* **Database Management** - Switch databases and servers at runtime (remote or in-process embedded server), list aliases
* **Discovery** - List tables, view schemas, get table structures (including descriptions, defaults, validators, policies, audit, and referential-integrity references), list indexes
* **Utility** - Count records, show query execution plan

## Requirements

* Delphi (RAD Studio 13) with NexusDB Komponente
* NexusDB NXserver running and accessible
* https://github.com/GDKsoftware/Delphi-MCP-Server (may have additional depencies)
* https://github.com/viniciussanchez/dataset-serialize — **requires a one-line patch** for
  `ftLongWord` columns (needed by `list_locks`; see [CHANGELOG.md](CHANGELOG.md) and
  [upstream issue #269](https://github.com/viniciussanchez/dataset-serialize/issues/269))
* Windows OS

## Configuration

On first run, `nxmcp.ini` is automatically created next to the executable with default values. Edit it to configure both the NexusDB connection and MCP server:

```ini
[Connection]
; Server mode: Remote (connect to an NXserver) or Embedded (in-process local server)
; In Embedded mode only [Database] AliasPath is used (no AliasName), and it must be set.
Mode=Remote
; NXserver host address (Remote mode only)
ServerHost=localhost
; NXserver port (default: 16000, Remote mode only)
ServerPort=16000

[Database]
; Set EITHER AliasName OR AliasPath (they are mutually exclusive; Embedded uses AliasPath only).
; If both are set, AliasPath takes precedence.
; Database alias as configured on the NXserver
AliasName=YourAlias
; Server-side filesystem path to the database folder (leave empty to use AliasName)
AliasPath=
; Table passwords, comma separated (leave empty if not used)
TablePassword=
; For a password that contains a literal comma, add it as TablePasswords1, TablePasswords2, ... instead

[Authentication]
; NexusDB username
Username=your_username
; NexusDB password
Password=your_password

[Options]
; Automatically connect on startup (1=yes, 0=no)
AutoConnect=1
; Per-operation NexusDB timeout in milliseconds
Timeout=3000
; Maximum time to wait for another database request to finish (0=fail fast)
BusyTimeout=3000
; Write log output to a file (1=yes, 0=no)
LogToFile=0
; Log file path (leave empty for <exe name>.log next to the executable)
LogFileName=

[Server]
; MCP server configuration
Port=3000
Host=localhost
Name=nxmcp
Version=6.0.0.0
Endpoint=/mcp

[CORS]
; Cross-Origin Resource Sharing configuration
Enabled=1
; Comma-separated list of allowed origins
AllowedOrigins=http://localhost,http://127.0.0.1,https://localhost,https://127.0.0.1

[SSL]
; SSL/TLS configuration (optional)
Enabled=0
CertFile=
KeyFile=
RootCertFile=
```  


## Building

1. Open `Source/nxmcp.dpr` in Delphi
2. Ensure NexusDB components and the MCP library are in your search path
3. Build the project (Ctrl+F9)

## Running

### Restricted or portable environments

During unit initialization, the NexusDB exception hook creates a per-executable
application-data directory below
`C:\ProgramData\NexusDB4\nxmcp\<encoded executable directory>`. Normal Windows
permissions allow regular users to create this directory. A sandbox, hardened service
account, or locked-down `ProgramData` ACL may not.

In such an environment, point NexusDB at a writable application-data directory:

```bat
nxmcp.exe /CONFIG:"C:\path\to\writable\nxmcp-state"
```

This switch controls NexusDB's application-data and exception-log location. It does not
move `nxmcp.ini`, which remains next to `nxmcp.exe`, and it does not change the configured
database path. If the default directory cannot be created, startup can fail before nxmcp's
own error handling runs, typically as runtime error 217 followed by an application-error
dialog.

### HTTP Transport (default)

```
nxmcp.exe
```

The server starts on `http://localhost:3000/mcp` by default.

### Concurrent HTTP clients

One nxmcp process currently owns one NexusDB session. Database-backed `tools/call` and
`resources/read` requests therefore execute one at a time; this prevents NexusDB's
`DBIERR_REENTERED` failure when several MCP clients share the HTTP endpoint. Waiting is
bounded by `[Options] BusyTimeout`. If the lease cannot be acquired in time, the request
returns a normal MCP error result saying the database is busy and no database operation was
started. `0` means fail fast; negative values are invalid and fall back to 3000 ms.

`[Options] Timeout` is separate: it limits the NexusDB operation itself. Changing it with
`set_timeout` does not change `BusyTimeout`. A general NexusDB timeout is reported once and
is never replayed; nxmcp best-effort cancels the outstanding work, retires the affected
session, and reconnects before releasing the execution lease. Discovery (`tools/list`,
`resources/list`, resource-template listing), `initialize`, and `ping` do not wait for the
database lease.

### STDIO Transport

```
nxmcp.exe --stdio
```

Uses stdin/stdout for JSON-RPC communication. Required for Claude Desktop and other MCP clients that use the STDIO transport.

## Available Tools

### Query \& Discovery

| Tool | Description | Parameters |
|------|-------------|------------|
| `execute_query` | Run SELECT queries | `sql`, `params?`, `maxRows?` |
| `get_table_schema` | Get table structure | `tableName` |

### Data Manipulation

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_table_data` | Read table data with pagination | `tableName`, `maxRows?`, `offset?`, `orderBy?` |
| `insert_record` | Insert a new record | `tableName`, `data` (JSON string) |
| `update_records` | Update matching records | `tableName`, `data` (JSON string), `whereClause` |
| `delete_records` | Delete matching records | `tableName`, `whereClause` |
| `execute_sql` | Run INSERT/UPDATE/DELETE | `sql`, `params?` |

### Schema Management

| Tool | Description | Parameters |
|------|-------------|------------|
| `create_table` | Create a new table | `tableName`, `columns` (JSON array), `description?` |
| `drop_table` | Delete a table | `tableName` |
| `copy_table` | Clone a table | `sourceTable`, `targetTable`, `copyData?` |
| `rename_table` | Rename a table | `oldName`, `newName` |
| `add_column` | Add a column | `tableName`, `columnName`, `columnType`, `size?`, `required?`, `description?`, `defaultValueType?`, `constantValue?`, `applyAt?`, `applyOnModify?`, `overwriteNonNull?` |
| `drop_column` | Remove a column | `tableName`, `columnName` |
| `modify_column` | Modify a column | `tableName`, `columnName`, `newType?`, `newSize?`, `newName?`, `required?` (`"true"`/`"false"`) |
| `create_index` | Create an index | `tableName`, `indexName`, `columns`, `unique?` |
| `drop_index` | Remove an index | `tableName`, `indexName` |

### Schema Metadata

| Tool | Description | Parameters |
|------|-------------|------------|
| `set_table_description` | Set or clear the description (comment) on a table | `tableName`, `description` |
| `set_column_description` | Set or clear the description on a column | `tableName`, `columnName`, `description` |
| `set_index_description` | Set or clear the description on an index | `tableName`, `indexName`, `description` |
| `set_field_validator` | Add/remove a server-side validator on a column (`minmax` or `nochange`, or `none` to remove) | `tableName`, `columnName`, `validator`, `minValue?`, `maxValue?`, `minNull?`, `maxNull?` |
| `set_column_default` | Add, replace, or clear the default-value descriptor on an existing column | `tableName`, `columnName`, `defaultType` (`none`/`CurrentDateTime`/`CurrentUser`/`Constant`), `constantValue?`, `applyAt?`, `applyOnInsert?`, `applyOnModify?`, `overwriteNonNull?` |
| `set_data_policies` | Set/clear table-level data policies: deny insert/modify/delete and enforce min/max record counts | `tableName`, `clear?`, `denyInsert?`, `denyModify?`, `denyDelete?`, `minRecordCount?`, `maxRecordCount?` |
| `set_audit` | Enable/disable audit-trail logging and BLOB inclusion (requires a server-side audit monitor for rows to be recorded) | `tableName`, `clear?`, `useAudit?`, `includeBlobFields?` |

`get_table_schema` reads directly from the table's `TnxDataDictionary` and surfaces description, per-column descriptions/defaults/validators, per-index descriptions, data policies, audit settings, and (read-only) referential-integrity references. `list_indexes` also includes each index's description.

### Table Maintenance

| Tool | Description | Parameters |
|------|-------------|------------|
| `empty_table` | Delete all records (keeps structure) | `tableName` |
| `pack_table` | Compact table, reclaim deleted space | `tableName` |
| `reindex_table` | Rebuild an index | `tableName`, `indexName` |
| `recover_table` | Recover records from broken table | `tableName` |
| `change_password` | Change table password | `tableName`, `oldPassword`, `newPassword` |
| `get_autoinc_value` | Get next auto-increment value | `tableName` |
| `close_inactive_tables` | Release the tables **and folders** the server keeps open in its cache for this session (frees server-side file handles) | _(none)_ |

### Transactions

| Tool | Description | Parameters |
|------|-------------|------------|
| `batch_execute` | Execute multiple SQL in one transaction | `statements` (JSON array), `snapshot?` |

### Utility

| Tool | Description | Parameters |
|------|-------------|------------|
| `count_records` | Fast record count via metadata | `tableName` |
| `list_indexes` | List all indexes on a table | `tableName` |
| `explain_query` | Show query execution plan | `sql` |
| `list_locks` | Report live lock state from `#TABLE_LOCKS` / `#TRANSACTION_LOCKS` (degrades gracefully on older servers) | `lockType?` (table/transaction/all), `tableName?`, `maxRows?` |

### Database Management

| Tool | Description | Parameters |
|------|-------------|------------|
| `list_aliases` | List available database aliases on the server | _(none)_ |
| `switch_database` | Switch to a different database alias or server-side path | `aliasName?`, `aliasPath?`, `tablePassword?` (provide either `aliasName` or `aliasPath`) |
| `switch_server` | Switch server connection (remote or embedded) | `mode?` (remote/embedded), `serverHost?`, `serverPort?`, `aliasName?`, `aliasPath?`, `tablePassword?` (embedded requires `aliasPath`) |

## Available Resources

| URI | Description |
|-----|-------------|
| `nexusdb://server` | Connection status and server info |
| `nexusdb://tables` | List of all tables |
| `nexusdb://schema` | Schema overview with record counts |

## Restricting the available tools

`nxmcp.ini` has a `[Tools]` and a `[Resources]` section listing every tool and resource:

```ini
[Tools]
; Set a tool to 0 to hide it: it is then not listed and cannot be called
; Anything not listed here is available - new tools need no ini change
execute_query=1
execute_sql=0
drop_table=0

[Resources]
nexusdb://server=1
nexusdb://schema=0
```

A tool set to `0` is not returned by `tools/list` and cannot be called - the client never
sees it. Same for resources and `resources/list` / `resources/read`.

**Everything is available by default.** Only entries explicitly set to `0` are switched
off, so an absent entry - or a tool added by a later version - is simply available, and
existing ini files keep working untouched. A freshly generated `nxmcp.ini` lists every
registered tool set to `1`, as a starting point to edit.

This is the low-effort way to narrow nxmcp to what a given deployment should be allowed to
do, without maintaining a fork.

## Security

nxmcp is a **development tool**: taken as a whole it can do anything to the target
database, by design. What each individual tool promises, however, is enforced.

| Tool | Contract |
|------|----------|
| `execute_query` | Strictly read-only. One SELECT, no second statement after a semicolon, no `INTO` clause. |
| `explain_query` | One SELECT/INSERT/UPDATE/DELETE (incl. `SELECT ... INTO`). **Executes the statement** (see below); writes run in a transaction that is always rolled back. DDL rejected. |
| `get_table_data`, `get_table_schema` | Read-only, confined to the exact table named. |
| `insert_record`, `update_records`, `delete_records`, `drop_index` | Confined to the table named; the operation cannot be redirected elsewhere. |
| `execute_sql`, `batch_execute` | **Unrestricted by design** - any statement, including DDL. No guarantees are made or enforced. |

Two things make those contracts hold:

* **Statement guards.** NexusDB executes a semicolon-separated batch submitted as a
  single `SQL.Text` in one call, so `SELECT * FROM t; DELETE FROM t` would otherwise run
  both. And `SELECT ... INTO` creates and populates a table, so it is a write that begins
  with SELECT. Statements are classified with NexusDB's own SQL lexer (`TnxSQLTokenizer`),
  so comments, string literals and quoted identifiers cannot be used to smuggle either
  past the check. Subselects are unaffected - they add no top-level semicolon, so
  `WHERE id IN (SELECT ...)` works normally in `update_records` / `delete_records`.
* **Identifier validation.** Table, column, index and `orderBy` names are concatenated
  into SQL, and NexusDB has **no escape syntax** for a quote inside a quoted identifier
  (`SELECT 1 AS "a""b"` is a syntax error). They are therefore validated with the engine's
  own `nxCheckValidTableName` / `nxCheckValidIdent`, whose character set excludes `"` and
  `;`. Everything NexusDB considers a legal name still works, including meta tables
  (`#TABLES`), memory/temp tables (`<name>`), child tables (`parent:child`) and names
  containing spaces.

**`explain_query` executes.** NexusDB has no non-executing explain - the plan is a
by-product of running the statement (`TnxQuery.Log` is filled from the execution round
trip; `Prepare` alone leaves it empty). A SELECT is harmless; INSERT/UPDATE/DELETE are
wrapped in a transaction and always rolled back, and the response reports `rolledBack`.
Once that transaction is open a lost connection is **not** retried - a retry would
reconnect first, discarding the transaction and committing the write - so it fails
instead, and the server rolls the transaction back on disconnect.

`SELECT ... INTO` can be profiled as well, with one caveat the response spells out in a
`note`: the rollback undoes the copied rows, but the table it creates is left behind
empty, because creating a table is not transactional. Drop it with `drop_table` if you did
not want it. DDL is rejected outright for that same reason.

**If you embed nxmcp in a product** rather than using it as a dev tool - especially where
an LLM composes SQL from untrusted input - point it at a NexusDB user with only the rights
that product needs. The guards above keep each tool to its contract, but `execute_sql` and
`batch_execute` remain deliberately unrestricted, so the connection's own rights are the
only limit on what the server will accept. A restricted user is a structural boundary; the
tool contracts are not a substitute for one. Alternatively, switch off the tools you do not
need in `[Tools]` (see above), or build your own fork restricted to the tools you deem
safe - each tool is a self-contained unit registered in `nxmcp.dpr`, so removing one is a
single line.

## Column Types

For `create_table` and `add_column`:

* `AutoInc` - Auto-incrementing integer
* `ShortString` - ANSI string (specify size)
* `WideString` - Unicode string (specify size)
* `Integer` - 32-bit integer
* `Int64` - 64-bit integer
* `Word` - 16-bit unsigned
* `Byte` - 8-bit unsigned
* `Boolean` - True/False
* `Float` - Double precision
* `Currency` - Currency type
* `DateTime` - Date and time
* `Date` - Date only
* `Time` - Time only
* `Blob` - Binary data
* `Memo` - Large text

## Column Options (required, descriptions, defaults)

`create_table`, `add_column`, and `modify_column` can declare column metadata directly — no separate call needed:

* **Required / NOT NULL** — `create_table` (per-column `"required": true`), `add_column` (`required`), `modify_column` (`required: "true"`/`"false"`). Making an existing column required can fail if records already hold null values.
* **AutoInc** — use the `AutoInc` column type.
* **Descriptions** — per-column `description` in `create_table`/`add_column`; a table-level `description` in `create_table`.
* **Default values** — see below.

In `create_table`, each column object accepts an optional `default` object, e.g.:

```json
{ "name": "CreatedAt", "type": "DateTime",
  "default": { "type": "CurrentDateTime", "applyOnInsert": true } }
```

## Default Value Types

For `add_column`, `create_table` (per-column `default.type`), and `set_column_default`:

* `CurrentDateTime` - Auto-populate with current timestamp
* `CurrentUser` - Auto-populate with current user
* `Constant` - Literal value (pass via `constantValue`)
* `none` - Remove any existing default (`set_column_default` only)

Default behaviour can be tuned with `applyAt` (`client`/`server`/`both`), `applyOnInsert`, `applyOnModify`, and `overwriteNonNull`.

## Statement Switches

Prefix SQL statements with switches to control execution:

| Switch | Syntax | Purpose |
|--------|--------|---------|
| `#T` | `#T 5000` | Timeout in milliseconds |
| `#I` | `#I-` | Disable index optimization |
| `#S` | `#S-` | Disable query simplification |
| `#L` | `#L+` | Enable query logging (used by `explain\_query`) |
| `#B` | `#B+` | Force BLOB copying |

Example: `#T 10000 SELECT * FROM LargeTable WHERE Status = 'Active'`

## Example Usage

### Create a table

```json
{
  "name": "create_table",
  "arguments": {
    "tableName": "Customers",
    "description": "Customer master data",
    "columns": "[{"name":"ID","type":"AutoInc"},{"name":"Name","type":"ShortString","size":100,"required":true,"description":"Display name"},{"name":"Email","type":"ShortString","size":255},{"name":"CreatedAt","type":"DateTime","default":{"type":"CurrentDateTime","applyOnInsert":true}}]"
  }
}
```

### Insert a record

```json
{
  "name": "insert_record",
  "arguments": {
    "tableName": "Customers",
    "data": "{"Name":"John Doe","Email":"john@example.com"}"
  }
}
```

### Query data

```json
{
  "name": "execute_query",
  "arguments": {
    "sql": "SELECT * FROM Customers WHERE Name LIKE 'J%'"
  }
}
```

### Parameterized queries

`execute_query` and `execute_sql` support named parameters: write `:name` placeholders
in the SQL and bind values through the optional `params` argument (a JSON array).
Values are bound natively — no quoting/escaping, and no `GUID '...'` / `TIMESTAMP '...'`
typed-literal syntax is needed for GUID, date, time, or datetime columns.

```json
{
  "name": "execute_query",
  "arguments": {
    "sql": "SELECT * FROM Orders WHERE CustomerGuid = :cust AND OrderDate >= :since AND Total > :min",
    "params": "[{\"name\":\"cust\",\"value\":\"d94660ff-6da8-4d0b-8358-12dacb46ccf9\",\"type\":\"guid\"},{\"name\":\"since\",\"value\":\"2024-01-15\",\"type\":\"date\"},{\"name\":\"min\",\"value\":100}]"
  }
}
```

Each entry is `{"name", "value", "type"?}`. `type` is optional and inferred from the
JSON value (number → integer/float, true/false → boolean, string → string); explicit
types: `string`, `memo`, `integer`, `float`, `currency`, `boolean`, `date`, `time`,
`datetime`, `guid`, `blob` (base64). `"value": null` binds a NULL. Date/time values
accept ISO 8601 input (`T` or space separator; a trailing `Z`/offset is stripped,
wall-clock preserved); GUIDs may be bare or braced, any case.

## Integration with Claude Code

### HTTP Transport
```bash
claude mcp add --transport http nxmcp http://localhost:3000/mcp
```

### STDIO Transport
```bash
claude mcp add nxmcp -- /path/to/nxmcp.exe --stdio
```

## Integration with Claude Desktop

Add to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "nxmcp": {
      "command": "C:\\path\\to\\nxmcp.exe",
      "args": ["--stdio"]
    }
  }
}
```


## License

The MIT License (MIT)

Copyright (c) 2025 Dr. Pfau Fernwirktechnik GmbH

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

