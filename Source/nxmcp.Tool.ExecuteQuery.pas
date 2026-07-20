unit nxmcp.Tool.ExecuteQuery;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Math,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the execute_query tool
  /// </summary>
  TExecuteQueryParams = class
  private
    FSql: string;
    FParams: string;
    FMaxRows: Integer;
    FLog: Boolean;
    FVerboseLog: Boolean;
  public
    [SchemaDescription('SQL SELECT query to execute. May contain :name parameter placeholders bound via params.')]
    property Sql: string read FSql write FSql;

    [Optional]
    [SchemaDescription('JSON array binding values to :name placeholders in the SQL, e.g. ' +
      '[{"name":"id","value":42},{"name":"since","value":"2024-01-15","type":"date"}]. ' +
      '"type" is optional (inferred from the JSON value: number, boolean, string); explicit types: ' +
      'string, memo, integer, float, currency, boolean, date, time, datetime, guid, blob (base64). ' +
      '"value":null binds NULL. Values are bound natively - no quoting or GUID/DATE/TIMESTAMP typed literals needed.')]
    property Params: string read FParams write FParams;

    [Optional]
    [SchemaDescription('Maximum number of rows to return (default: 100, max: 10000)')]
    property MaxRows: Integer read FMaxRows write FMaxRows;

    [Optional]
    [SchemaDescription('Enable query log (#L+) to capture execution plan summary in the response')]
    property Log: Boolean read FLog write FLog;

    [Optional]
    [SchemaDescription('Enable verbose log (#V+) to capture full optimizer internals in the response')]
    property VerboseLog: Boolean read FVerboseLog write FVerboseLog;
  end;

  /// <summary>
  /// MCP Tool that executes SQL SELECT queries and returns JSON results
  /// </summary>
  TExecuteQueryTool = class(TMCPToolBase<TExecuteQueryParams>)
  protected
    function ExecuteWithParams(const Params: TExecuteQueryParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  DataSet.Serialize,
  MCPServer.Registration,
  nxmcp.SqlUtils,
  nxmcp.QueryParams,
  dmnx;

{ TExecuteQueryTool }

constructor TExecuteQueryTool.Create;
begin
  inherited;
  FName := 'execute_query';
  FTitle := 'Execute SQL Query';
  FDescription := 'Execute a SQL SELECT query against the NexusDB database and return results as JSON. ' +
                  'Use this for reading data. For INSERT/UPDATE/DELETE, use execute_sql instead. ' +
                  'Supports named parameters: write :name placeholders in the SQL and supply values via params ' +
                  '(preferred over embedding values in the SQL - no escaping or typed-literal syntax needed). ' +
                  'Statement switches can be prefixed: #T ms (timeout), #I- (disable index optimization), ' +
                  '#S- (disable simplification), #B+ (force BLOB copy). Example: "#T 5000 SELECT * FROM large_table"';
end;

function TExecuteQueryTool.ExecuteWithParams(const Params: TExecuteQueryParams): string;
var
  LMaxRows: Integer;
  LRowCount: Integer;
  LJSONArray: TJSONArray;
  LResultObj: TJSONObject;
  LSql: string;
  LHasLog: Boolean;
begin
  // Validate parameters
  if Trim(Params.Sql) = '' then
    raise Exception.Create('SQL query cannot be empty');

  // Check for non-SELECT statements (strip statement switches like #T, #I, #S, #L, #B, #V first)
  if not IsSelectStatement(Params.Sql) then
    raise Exception.Create('Only SELECT queries are allowed. Use execute_sql for other statements.');

  // Determine max rows
  if Params.MaxRows > 0 then
    LMaxRows := Min(Params.MaxRows, 10000)
  else
    LMaxRows := 100;

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

  // Execute query (auto-reconnects and retries once on lost connection)
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
        nxmodule.nxQuery1.Open;
      end);
  except
    on E: Exception do
    begin
      // If log was requested, include it even on failure (TnxQuery populates Log before raising)
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

  try
    // Build JSON array, returning at most LMaxRows rows
    LRowCount := 0;
    LJSONArray := TJSONArray.Create;
    try
      nxmodule.nxQuery1.First;
      while (not nxmodule.nxQuery1.Eof) and (LRowCount < LMaxRows) do
      begin
        LJSONArray.AddElement(nxmodule.nxQuery1.ToJSONObject);
        Inc(LRowCount);
        nxmodule.nxQuery1.Next;
      end;

      // Build result with metadata
      LResultObj := TJSONObject.Create;
      try
        LResultObj.AddPair('rowCount', TJSONNumber.Create(LRowCount));
        LResultObj.AddPair('maxRows', TJSONNumber.Create(LMaxRows));
        LResultObj.AddPair('truncated', TJSONBool.Create(not nxmodule.nxQuery1.Eof));
        LResultObj.AddPair('data', LJSONArray);

        // Include log output if requested
        if LHasLog then
          LResultObj.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));

        Result := LResultObj.ToJSON;
      finally
        // Note: LJSONArray ownership transferred to LResultObj
        LResultObj.Free;
      end;
    except
      LJSONArray.Free;
      raise;
    end;
  finally
    nxmodule.nxQuery1.Close;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('execute_query',
    function: IMCPTool
    begin
      Result := TExecuteQueryTool.Create;
    end
  );

end.
