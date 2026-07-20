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
  dmnx;

{ TGetQueryLogTool }

constructor TGetQueryLogTool.Create;
begin
  inherited;
  FName := 'get_query_log';
  FTitle := 'Get Query Log';
  FDescription := 'Return the query log from the most recent query execution. ' +
                  'The log is populated by NexusDB even if the query failed (e.g. timeout). ' +
                  'Returns an empty log if no query has been executed or if logging was not enabled.';
end;

function TGetQueryLogTool.ExecuteWithParams(const Params: TGetQueryLogParams): string;
var
  LResultObj: TJSONObject;
  LLogArray: TJSONArray;
  I: Integer;
begin
  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  LResultObj := TJSONObject.Create;
  try
    LLogArray := TJSONArray.Create;
    for I := 0 to nxmodule.nxQuery1.Log.Count - 1 do
      LLogArray.Add(nxmodule.nxQuery1.Log[I]);
    LResultObj.AddPair('lineCount', TJSONNumber.Create(nxmodule.nxQuery1.Log.Count));
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
