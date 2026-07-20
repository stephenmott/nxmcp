unit nxmcp.Tool.GetAutoIncValue;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the get_autoinc_value tool
  /// </summary>
  TGetAutoIncValueParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to get auto-increment value from')]
    property TableName: string read FTableName write FTableName;
  end;

  /// <summary>
  /// MCP Tool that gets the next auto-increment value for a table
  /// </summary>
  TGetAutoIncValueTool = class(TMCPToolBase<TGetAutoIncValueParams>)
  protected
    function ExecuteWithParams(const Params: TGetAutoIncValueParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxllTypes,
  MCPServer.Registration,
  dmnx;

{ TGetAutoIncValueTool }

constructor TGetAutoIncValueTool.Create;
begin
  inherited;
  FName := 'get_autoinc_value';
  FTitle := 'Get Auto-Increment Value';
  FDescription := 'Get the next auto-increment value for a table.';
end;

function TGetAutoIncValueTool.ExecuteWithParams(const Params: TGetAutoIncValueParams): string;
var
  LResultObj: TJSONObject;
  LValue: TnxWord32;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Get auto-increment value (auto-reconnects and retries once on lost connection)
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      nxmodule.nxDatabase1.GetAutoIncValue(Params.TableName, nxmodule.TablePassword, LValue);
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('nextAutoIncValue', TJSONNumber.Create(LValue));
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('get_autoinc_value',
    function: IMCPTool
    begin
      Result := TGetAutoIncValueTool.Create;
    end
  );

end.
