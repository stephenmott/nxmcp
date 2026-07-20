unit nxmcp.Tool.SetTimeout;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the set_timeout tool
  /// </summary>
  TSetTimeoutParams = class
  private
    FTimeout: Integer;
  public
    [SchemaDescription('Timeout value in milliseconds (0 = no timeout, -1 = use parent component''s timeout)')]
    property Timeout: Integer read FTimeout write FTimeout;
  end;

  /// <summary>
  /// MCP Tool that sets the timeout on the NexusDB database component.
  /// Controls how long operations wait before timing out.
  /// </summary>
  TSetTimeoutTool = class(TMCPToolBase<TSetTimeoutParams>)
  protected
    function ExecuteWithParams(const Params: TSetTimeoutParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TSetTimeoutTool }

constructor TSetTimeoutTool.Create;
begin
  inherited;
  FName := 'set_timeout';
  FTitle := 'Set Database Timeout';
  FDescription := 'Set the timeout on the NexusDB database component. ' +
                  'Controls how long operations wait before timing out. ' +
                  'Value is in milliseconds (0 = no timeout, -1 = use parent component''s timeout).';
end;

function TSetTimeoutTool.ExecuteWithParams(const Params: TSetTimeoutParams): string;
var
  LResultObj: TJSONObject;
  LOldTimeout: Integer;
begin
  // Validate parameters
  if Params.Timeout < -1 then
    raise Exception.Create('Timeout cannot be less than -1');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Get old value for reporting
  LOldTimeout := nxmodule.nxDatabase1.Timeout;

  // Set the timeout
  nxmodule.nxDatabase1.Timeout := Params.Timeout;

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('previousTimeout', TJSONNumber.Create(LOldTimeout));
    LResultObj.AddPair('newTimeout', TJSONNumber.Create(Params.Timeout));
    LResultObj.AddPair('message', 'Database timeout set to ' + IntToStr(Params.Timeout) + ' ms');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('set_timeout',
    function: IMCPTool
    begin
      Result := TSetTimeoutTool.Create;
    end
  );

end.
