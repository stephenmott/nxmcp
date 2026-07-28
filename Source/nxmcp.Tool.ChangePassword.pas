unit nxmcp.Tool.ChangePassword;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  /// <summary>
  /// Parameters for the change_password tool
  /// </summary>
  TChangePasswordParams = class
  private
    FTableName: string;
    FOldPassword: string;
    FNewPassword: string;
  public
    [SchemaDescription('Name of the table to change password for')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Current password of the table (empty string if no password)')]
    property OldPassword: string read FOldPassword write FOldPassword;

    [SchemaDescription('New password for the table (empty string to remove password)')]
    property NewPassword: string read FNewPassword write FNewPassword;
  end;

  /// <summary>
  /// MCP Tool that changes a table's password
  /// </summary>
  TChangePasswordTool = class(TSerializedToolBase<TChangePasswordParams>)
  protected
    function ExecuteWithParams(const Params: TChangePasswordParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxllException,
  MCPServer.Registration,
  dmnx;

{ TChangePasswordTool }

constructor TChangePasswordTool.Create;
begin
  inherited;
  FName := 'change_password';
  FTitle := 'Change Table Password';
  FDescription := 'Change the password of a table. Use empty string to remove password protection.';
end;

function TChangePasswordTool.ExecuteWithParams(const Params: TChangePasswordParams): string;
var
  LResultObj: TJSONObject;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Close any open tables to avoid conflicts
  nxmodule.nxSession1.CloseInactiveTables;

  // Change password (auto-reconnects and retries once on lost connection)
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      nxCheck(nxmodule.nxDatabase1.ChangePasswordEx(Params.TableName, Params.OldPassword, Params.NewPassword));
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    if Params.NewPassword = '' then
      LResultObj.AddPair('message', 'Password removed successfully')
    else
      LResultObj.AddPair('message', 'Password changed successfully');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('change_password',
    function: IMCPTool
    begin
      Result := TChangePasswordTool.Create;
    end
  );

end.
