unit nxmcp.ExclusiveTools;

interface

uses
  System.JSON;

/// <summary>
/// True for tool calls that must hold every pooled session: target switches,
/// set_timeout, cache release, schema changes and table maintenance (these need
/// the table closed in every session), and execute_sql / batch_execute whenever
/// they carry anything other than plain DML.
/// </summary>
function IsExclusiveTool(const AName: string; const AArguments: TJSONObject): Boolean;

implementation

uses
  System.SysUtils,
  nxmcp.SqlUtils;

const
  // Tools that change the pool's target or settings, or that alter / need sole
  // access to an existing table. Creating a new table (create_table, copy_table)
  // conflicts with nobody and stays shared.
  ExclusiveTools: array[0..22] of string = (
    'switch_database', 'switch_server', 'set_timeout', 'close_inactive_tables',
    'drop_table', 'rename_table', 'add_column', 'drop_column', 'modify_column',
    'create_index', 'drop_index', 'set_table_description',
    'set_column_description', 'set_index_description', 'set_field_validator',
    'set_column_default', 'set_data_policies', 'set_audit', 'empty_table',
    'pack_table', 'reindex_table', 'recover_table', 'change_password');

function IsPlainDml(const ASql: string): Boolean;
var
  LFacts: TnxSqlFacts;
begin
  // Anything that is not a single, recognisable DML statement is treated as a
  // possible schema change: better to wait for the other sessions than to fail
  // with "table in use" because one of them still caches the table. SELECT ... INTO
  // creates a table; INSERT INTO is ordinary DML (HasInto is set for both).
  try
    LFacts := AnalyzeSql(ASql);
  except
    Exit(False);
  end;
  Result := LFacts.IsSingle and
    (((LFacts.Kind = skSelect) and not LFacts.HasInto) or
     (LFacts.Kind in [skInsert, skUpdate, skDelete]));
end;

function StringArgument(const AArguments: TJSONObject; const AKey: string;
  out AValue: string): Boolean;
var
  LPair: TJSONPair;
begin
  // Tool argument keys are matched case-insensitively by the serializer.
  Result := False;
  AValue := '';
  if not Assigned(AArguments) then
    Exit;
  for LPair in AArguments do
    if SameText(LPair.JsonString.Value, AKey) then
    begin
      AValue := LPair.JsonValue.Value;
      Exit(True);
    end;
end;

function AllStatementsArePlainDml(const AStatements: string): Boolean;
var
  LValue: TJSONValue;
  LItem: TJSONValue;
begin
  LValue := TJSONObject.ParseJSONValue(AStatements);
  try
    // Malformed input is rejected by the tool itself; run that rejection shared.
    if not (LValue is TJSONArray) then
      Exit(True);
    for LItem in TJSONArray(LValue) do
      if not IsPlainDml(LItem.Value) then
        Exit(False);
    Result := True;
  finally
    LValue.Free;
  end;
end;

function IsExclusiveTool(const AName: string; const AArguments: TJSONObject): Boolean;
var
  LName: string;
  LValue: string;
begin
  for LName in ExclusiveTools do
    if SameText(LName, AName) then
      Exit(True);

  if SameText(AName, 'execute_sql') then
    Exit(StringArgument(AArguments, 'sql', LValue) and not IsPlainDml(LValue));

  if SameText(AName, 'batch_execute') then
    Exit(StringArgument(AArguments, 'statements', LValue) and
      not AllStatementsArePlainDml(LValue));

  Result := False;
end;

end.
