unit nxmcp.Tool.GetQueryLog;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the get_query_log tool (no parameters needed)
  /// </summary>
  TGetQueryLogParams = class
  end;

  /// <summary>
  /// MCP Tool that returns the query log from the most recent query execution.
  /// The log is populated by TnxQuery even if the query failed.
  /// </summary>
  TGetQueryLogTool = class(TMCPToolBase<TGetQueryLogParams>)
  protected
    function ExecuteWithParams(const Params: TGetQueryLogParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  nxmcp.SessionPool;

{ TGetQueryLogTool }

constructor TGetQueryLogTool.Create;
begin
  inherited;
  FName := 'get_query_log';
  FTitle := 'Get Query Log';
  FDescription := 'Return the query log from the most recent query execution that produced one ' +
                  '(by any client; the log is shared across the pooled sessions). ' +
                  'The log is populated by NexusDB even if the query failed (e.g. timeout). ' +
                  'Returns an empty log if no query with logging enabled (#L+ / #V+, or a tool''s log option) has run yet.';
end;

function TGetQueryLogTool.ExecuteWithParams(const Params: TGetQueryLogParams): string;
var
  LResultObj: TJSONObject;
  LLogArray: TJSONArray;
  LLog: TArray<string>;
  LLine: string;
begin
  // Read from the pool, not from nxmodule.nxQuery1: this call may be served by a
  // different pooled session than the query whose log is wanted. No database
  // round-trip is involved, so no connection is needed.
  LLog := NexusPool.LastQueryLog;

  LResultObj := TJSONObject.Create;
  try
    LLogArray := TJSONArray.Create;
    for LLine in LLog do
      LLogArray.Add(LLine);
    LResultObj.AddPair('lineCount', TJSONNumber.Create(Length(LLog)));
    LResultObj.AddPair('log', LLogArray);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('get_query_log',
    function: IMCPTool
    begin
      Result := TGetQueryLogTool.Create;
    end
  );

end.
