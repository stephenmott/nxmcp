unit nxmcp.Tool.ExecuteSQL;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the execute_sql tool
  /// </summary>
  TExecuteSQLParams = class
  private
    FSql: string;
    FParams: string;
    FLog: Boolean;
    FVerboseLog: Boolean;
  public
    [SchemaDescription('SQL statement to execute (INSERT, UPDATE, DELETE, or other non-SELECT statements). ' +
      'May contain :name parameter placeholders bound via params.')]
    property Sql: string read FSql write FSql;

    [Optional]
    [SchemaDescription('JSON array binding values to :name placeholders in the SQL, e.g. ' +
      '[{"name":"id","value":42},{"name":"since","value":"2024-01-15","type":"date"}]. ' +
      '"type" is optional (inferred from the JSON value: number, boolean, string); explicit types: ' +
      'string, memo, integer, float, currency, boolean, date, time, datetime, guid, blob (base64). ' +
      '"value":null binds NULL. Values are bound natively - no quoting or GUID/DATE/TIMESTAMP typed literals needed.')]
    property Params: string read FParams write FParams;

    [Optional]
    [SchemaDescription('Enable query log (#L+) to capture execution plan summary in the response')]
    property Log: Boolean read FLog write FLog;

    [Optional]
    [SchemaDescription('Enable verbose log (#V+) to capture full optimizer internals in the response')]
    property VerboseLog: Boolean read FVerboseLog write FVerboseLog;
  end;

  /// <summary>
  /// MCP Tool that executes SQL statements (INSERT, UPDATE, DELETE)
  /// </summary>
  TExecuteSQLTool = class(TMCPToolBase<TExecuteSQLParams>)
  protected
    function ExecuteWithParams(const Params: TExecuteSQLParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  MCPServer.Registration,
  nxmcp.SqlUtils,
  nxmcp.QueryParams,
  dmnx;

{ TExecuteSQLTool }

constructor TExecuteSQLTool.Create;
begin
  inherited;
  FName := 'execute_sql';
  FTitle := 'Execute SQL Statement';
  FDescription := 'Execute a SQL statement (INSERT, UPDATE, DELETE) against the NexusDB database. ' +
                  'Returns the number of rows affected. For SELECT queries, use execute_query instead. ' +
                  'Supports named parameters: write :name placeholders in the SQL and supply values via params ' +
                  '(preferred over embedding values in the SQL - no escaping or typed-literal syntax needed). ' +
                  'Statement switches can be prefixed: #T ms (timeout). Example: "#T 10000 DELETE FROM large_table WHERE old = 1"';
end;

function TExecuteSQLTool.ExecuteWithParams(const Params: TExecuteSQLParams): string;
var
  LResultObj: TJSONObject;
  LRowsAffected: Integer;
  LSqlUpper: string;
  LSql: string;
  LHasLog: Boolean;
begin
  // Validate parameters
  if Trim(Params.Sql) = '' then
    raise Exception.Create('SQL statement cannot be empty');

  // Check for SELECT statements - those should use execute_query
  // Strip statement switches (#T, #I, #S, #L, #B, #V) before checking
  LSqlUpper := StripSwitches(Params.Sql).ToUpper;
  if LSqlUpper.StartsWith('SELECT') then
    raise Exception.Create('SELECT queries are not allowed. Use execute_query for SELECT statements.');

  // Check connection (transparently reconnects if dropped)
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Prepend log switch if requested
  LSql := Params.Sql;
  LHasLog := Params.VerboseLog or Params.Log;
  if Params.VerboseLog then
    LSql := '#V+ ' + LSql
  else if Params.Log then
    LSql := '#L+ ' + LSql;

  // Execute SQL (auto-reconnects and retries once on lost connection)
  try
    nxmodule.ExecuteWithReconnect(
      procedure
      begin
        nxmodule.nxQuery1.Close;
        // Drop bindings left over from a previous statement: setting SQL.Text
        // carries old values onto same-named params (TParams.AssignValues),
        // which would defeat the missing-parameter check below.
        nxmodule.nxQuery1.Params.Clear;
        nxmodule.nxQuery1.SQL.Text := LSql;
        ApplyJsonParamsToQuery(nxmodule.nxQuery1, Params.Params);
        nxmodule.nxQuery1.ExecSQL;
      end);
  except
    on E: Exception do
    begin
      // If log was requested, include it even on failure
      if LHasLog and (nxmodule.nxQuery1.Log.Count > 0) then
      begin
        LResultObj := TJSONObject.Create;
        try
          LResultObj.AddPair('error', E.Message);
          LResultObj.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));
          Result := LResultObj.ToJSON;
        finally
          LResultObj.Free;
        end;
        Exit;
      end;
      raise;
    end;
  end;
  LRowsAffected := nxmodule.nxQuery1.RowsAffected;

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('rowsAffected', TJSONNumber.Create(LRowsAffected));
    LResultObj.AddPair('statement', Copy(LSqlUpper, 1, Pos(' ', LSqlUpper + ' ') - 1));

    // Include log output if requested
    if LHasLog then
      LResultObj.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));

    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('execute_sql',
    function: IMCPTool
    begin
      Result := TExecuteSQLTool.Create;
    end
  );

end.
