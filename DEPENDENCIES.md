# Dependencies

The external code nxmcp is built against. Versions are not pinned anywhere in the
project files, so they are recorded here.

| Library | Version used | Stock? |
|---|---|---|
| [Delphi-MCP-Server](https://github.com/GDKsoftware/Delphi-MCP-Server) | `4e98e3b` (2026-07-30) | yes |
| [dataset-serialize](https://github.com/viniciussanchez/dataset-serialize) | `1330615` (2025-11-17) | no — one patch, see below |
| NexusDB | 4.75 (commercial) | yes |

Delphi 13 / RAD Studio 37, Win64.

## dataset-serialize: ftLongWord patch required

Upstream serialises `ftLongWord` through `AsInteger`, which raises
`RangeError(Value, 0, High(Integer))` for any value above 2 147 483 647 — so a table
with a Cardinal-range column breaks every tool that returns rows. Apply this to
`src/DataSet.Serialize.Export.pas`, in the field-type case:

```pascal
{$IF NOT DEFINED(FPC)}
TFieldType.ftLongWord:
  Result.AddPair(LKey, TJSONNumber.Create(LField.AsLargeInt));
{$ENDIF}
```

and remove `TFieldType.ftLongWord` from the `ftInteger` branch above it. The fix is not
in upstream at any commit, so it must be re-applied after every update.
