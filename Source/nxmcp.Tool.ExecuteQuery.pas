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
  FDescription := 'Execute a single SQL SELECT query against the NexusDB database and return ' +
                  'results as JSON. Strictly read-only: exactly one statement (no second ' +
                  'statement after a semicolon) and no INTO clause. ' +
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
  LJsonResult: string;
  LHasLog: Boolean;
  LFacts: TnxSqlFacts;
  LFailureLog: TJSONArray;
begin
  // Validate parameters
  if Trim(Params.Sql) = '' then
    raise Exception.Create('SQL query cannot be empty');

  // This tool's contract is "reads only". NexusDB executes a semicolon-separated
  // batch submitted as one SQL.Text in a single call, and SELECT ... INTO creates
  // and populates a table, so a bare StartsWith('SELECT') is not enough to hold
  // that contract - both are writes that begin with SELECT.
  LFacts := AnalyzeSql(Params.Sql);
  if LFacts.Kind = skUnparsable then
    raise Exception.Create('SQL could not be parsed. Check the statement syntax.');
  if LFacts.Kind <> skSelect then
    raise Exception.Create('Only SELECT queries are allowed. Use execute_sql for other statements.');
  if not LFacts.IsSingle then
    raise Exception.Create('Only a single SELECT is allowed - a second statement after a ' +
      'semicolon would also be executed. Use batch_execute to run several statements.');
  if LFacts.HasInto then
    raise Exception.Create('SELECT ... INTO creates and populates a table, so it is not a ' +
      'read. Use execute_sql for it.');

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

  LJSONArray := nil;
  LResultObj := nil;
  LFailureLog := nil;
  try
    // Keep opening, reading, and closing in one retryable action. A lost
    // session during cursor traversal must rebuild the complete result on the
    // fresh session rather than retrying only the Open call.
    try
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          // Reset any partial result left by an earlier attempt before the
          // retry allocates a new cursor result.
          LResultObj.Free;
          LResultObj := nil;
          LJSONArray.Free;
          LJSONArray := nil;
          try
            nxmodule.nxQuery1.Close;
            // Drop bindings left over from a previous statement: setting SQL.Text
            // carries old values onto same-named params (TParams.AssignValues),
            // which would defeat the missing-parameter check below.
            nxmodule.nxQuery1.Params.Clear;
            nxmodule.nxQuery1.SQL.Text := LSql;
            ApplyJsonParamsToQuery(nxmodule.nxQuery1, Params.Params);
            nxmodule.nxQuery1.Open;

            // Build JSON array, returning at most LMaxRows rows.
            LRowCount := 0;
            LJSONArray := TJSONArray.Create;
            nxmodule.nxQuery1.First;
            while (not nxmodule.nxQuery1.Eof) and (LRowCount < LMaxRows) do
            begin
              LJSONArray.AddElement(nxmodule.nxQuery1.ToJSONObject);
              Inc(LRowCount);
              nxmodule.nxQuery1.Next;
            end;

            // Build result with metadata. Transfer the array explicitly so
            // the action's cleanup cannot free data owned by the object.
            LResultObj := TJSONObject.Create;
            LResultObj.AddPair('rowCount', TJSONNumber.Create(LRowCount));
            LResultObj.AddPair('maxRows', TJSONNumber.Create(LMaxRows));
            LResultObj.AddPair('truncated', TJSONBool.Create(not nxmodule.nxQuery1.Eof));
            LResultObj.AddPair('data', LJSONArray);
            LJSONArray := nil;

            // Include log output if requested.
            if LHasLog then
              LResultObj.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));

            LJsonResult := LResultObj.ToJSON;
          finally
            LResultObj.Free;
            LResultObj := nil;
            LJSONArray.Free;
            LJSONArray := nil;
            nxmodule.nxQuery1.Close;
          end;
        end,
        procedure(E: Exception)
        begin
          // Recovery rebuilds nxQuery1, so preserve diagnostics before it can
          // discard the failed session's log. Keep an earlier snapshot if a
          // later poisoned attempt has no log of its own.
          if LHasLog and (nxmodule.nxQuery1.Log.Count > 0) then
          begin
            LFailureLog.Free;
            LFailureLog := LogToJSONArray(nxmodule.nxQuery1.Log);
          end;
        end);
      Result := LJsonResult;
    except
      on E: Exception do
      begin
        // A poisoned-session failure has already gone through recovery. Use
        // the pre-recovery snapshot; ordinary errors retain the old live-log
        // behavior.
        if LHasLog then
        begin
          LResultObj := TJSONObject.Create;
          try
            LResultObj.AddPair('error', E.Message);
            if Assigned(LFailureLog) then
            begin
              LResultObj.AddPair('log', LFailureLog);
              LFailureLog := nil;
            end
            else if Assigned(nxmodule) and (nxmodule.nxQuery1.Log.Count > 0) then
              LResultObj.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));
            if LResultObj.GetValue('log') <> nil then
            begin
              Result := LResultObj.ToJSON;
              Exit;
            end;
          finally
            LResultObj.Free;
            LResultObj := nil;
          end;
        end;
        raise;
      end;
    end;
  finally
    LFailureLog.Free;
    LFailureLog := nil;
    LResultObj.Free;
    LResultObj := nil;
    LJSONArray.Free;
    LJSONArray := nil;
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
