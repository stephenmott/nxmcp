unit nxmcp.Tool.ExplainQuery;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the explain_query tool
  /// </summary>
  TExplainQueryParams = class
  private
    FSql: string;
    FVerbose: Boolean;
  public
    [SchemaDescription('SQL SELECT query to analyze')]
    property Sql: string read FSql write FSql;
    [SchemaDescription('Use verbose mode (#V+) for full optimizer internals: all indexes considered, relation analysis, decision process. Default is standard mode (#L+) showing plan summary.')]
    property Verbose: Boolean read FVerbose write FVerbose;
  end;

  /// <summary>
  /// MCP Tool that returns the execution plan for a query.
  /// Uses NexusDB query logging to show how the query will be executed.
  /// </summary>
  TExplainQueryTool = class(TMCPToolBase<TExplainQueryParams>)
  protected
    function ExecuteWithParams(const Params: TExplainQueryParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.StrUtils,
  Data.DB,
  MCPServer.Registration,
  dmnx;

{ TExplainQueryTool }

constructor TExplainQueryTool.Create;
begin
  inherited;
  FName := 'explain_query';
  FTitle := 'Explain Query Plan';
  FDescription := 'Show the execution plan for a SQL query. ' +
                  'Standard mode (#L+) shows plan summary: index used, join strategy, rows read. ' +
                  'Verbose mode (#V+) shows full optimizer internals: all available indexes, ' +
                  'relation analysis, index selection decisions, simplification steps. ' +
                  'You can add #I- to disable index optimization or #S- to disable simplification ' +
                  'to compare different execution plans.';
end;

function TExplainQueryTool.ExecuteWithParams(const Params: TExplainQueryParams): string;
var
  LResultObj: TJSONObject;
  LPlanArray: TJSONArray;
  LSwitch: string;
  I: Integer;
begin
  // Validate parameters
  if Trim(Params.Sql) = '' then
    raise Exception.Create('SQL query cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Choose logging switch: #V+ for verbose, #L+ for standard
  if Params.Verbose then
    LSwitch := '#V+'
  else
    LSwitch := '#L+';

  // Execute query with logging enabled (auto-reconnects and retries once on lost connection)
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      nxmodule.nxQuery1.Close;
      nxmodule.nxQuery1.SQL.Text := LSwitch + ' ' + Params.Sql;
      nxmodule.nxQuery1.Open;
    end);

  try
    // Build result from Log property
    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('sql', Params.Sql);
      LResultObj.AddPair('mode', IfThen(Params.Verbose, 'verbose', 'standard'));

      LPlanArray := TJSONArray.Create;
      for I := 0 to nxmodule.nxQuery1.Log.Count - 1 do
        LPlanArray.Add(nxmodule.nxQuery1.Log[I]);

      LResultObj.AddPair('plan', LPlanArray);
      LResultObj.AddPair('lineCount', TJSONNumber.Create(nxmodule.nxQuery1.Log.Count));

      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
  finally
    nxmodule.nxQuery1.Close;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('explain_query',
    function: IMCPTool
    begin
      Result := TExplainQueryTool.Create;
    end
  );

end.
