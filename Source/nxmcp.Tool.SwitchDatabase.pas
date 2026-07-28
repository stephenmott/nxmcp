unit nxmcp.Tool.SwitchDatabase;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  /// <summary>
  /// Parameters for the switch_database tool
  /// </summary>
  TSwitchDatabaseParams = class
  private
    FAliasName: string;
    FAliasPath: string;
    FTablePassword: string;
  public
    [Optional]
    [SchemaDescription('Database alias name to switch to (as configured on the NexusDB server). ' +
      'Provide either aliasName or aliasPath, not both.')]
    property AliasName: string read FAliasName write FAliasName;

    [Optional]
    [SchemaDescription('Server-side filesystem path to the database folder to switch to ' +
      '(as seen by the NexusDB server, e.g. C:\Data\MyDB). ' +
      'Provide either aliasName or aliasPath, not both.')]
    property AliasPath: string read FAliasPath write FAliasPath;

    [Optional]
    [SchemaDescription('Table password for the new database (leave empty if not needed)')]
    property TablePassword: string read FTablePassword write FTablePassword;
  end;

  /// <summary>
  /// MCP Tool that switches the active database to a different alias
  /// </summary>
  TSwitchDatabaseTool = class(TSerializedToolBase<TSwitchDatabaseParams>)
  protected
    function ExecuteWithParams(const Params: TSwitchDatabaseParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TSwitchDatabaseTool }

constructor TSwitchDatabaseTool.Create;
begin
  inherited;
  FName := 'switch_database';
  FTitle := 'Switch Database';
  FDescription := 'Switch the active database on the NexusDB server. ' +
                  'Provide EITHER aliasName (a server-configured alias) OR aliasPath ' +
                  '(a server-side filesystem path to the database folder) - the two are ' +
                  'mutually exclusive. The transport and session remain connected; only the ' +
                  'database is changed. In embedded mode only aliasPath is valid and it must ' +
                  'be an existing directory - a bad path is rejected up front and the current ' +
                  'connection is left untouched. If switching fails, the server attempts to ' +
                  'reconnect to the previous database. Use list_aliases to see available aliases.';
end;

function TSwitchDatabaseTool.ExecuteWithParams(const Params: TSwitchDatabaseParams): string;
var
  LResultObj: TJSONObject;
  LOldAlias: string;
  LOldPath: string;
  LUsePath: Boolean;
  LAlreadyThere: Boolean;
begin
  // Validate parameters: exactly one of aliasName / aliasPath must be provided.
  if (Trim(Params.AliasName) = '') and (Trim(Params.AliasPath) = '') then
    raise Exception.Create('Provide either aliasName or aliasPath');
  if (Trim(Params.AliasName) <> '') and (Trim(Params.AliasPath) <> '') then
    raise Exception.Create('Provide either aliasName or aliasPath, not both');

  LUsePath := Trim(Params.AliasPath) <> '';

  // Check that nxmodule is assigned
  if not Assigned(nxmodule) then
    raise Exception.Create('NexusDB module not initialized');

  // Bring the session back if it dropped. EnsureSession rather than
  // EnsureConnection: the database being switched away from may be precisely the
  // one that will not open, and requiring it would block the escape route.
  if not nxmodule.EnsureSession then
    raise Exception.Create('Not connected to NexusDB server: ' + nxmodule.GetLastError);

  // Check if already on this target
  if LUsePath then
    LAlreadyThere := SameText(Params.AliasPath, nxmodule.AliasPath)
  else
    LAlreadyThere := SameText(Params.AliasName, nxmodule.AliasName);

  if LAlreadyThere and nxmodule.IsConnected then
  begin
    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('success', TJSONBool.Create(True));
      LResultObj.AddPair('message', 'Already connected to this database');
      LResultObj.AddPair('aliasName', nxmodule.AliasName);
      LResultObj.AddPair('aliasPath', nxmodule.AliasPath);
      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
    Exit;
  end;

  // Remember previous target for reporting
  LOldAlias := nxmodule.AliasName;
  LOldPath := nxmodule.AliasPath;

  // Perform the switch (both variants handle rollback on failure)
  if LUsePath then
    nxmodule.SwitchDatabaseByPath(Params.AliasPath, Params.TablePassword)
  else
    nxmodule.SwitchDatabase(Params.AliasName, Params.TablePassword);

  // Build success result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('previousAlias', LOldAlias);
    LResultObj.AddPair('previousAliasPath', LOldPath);
    LResultObj.AddPair('currentAlias', nxmodule.AliasName);
    LResultObj.AddPair('currentAliasPath', nxmodule.AliasPath);
    LResultObj.AddPair('connected', TJSONBool.Create(nxmodule.IsConnected));
    if Params.TablePassword <> '' then
      LResultObj.AddPair('passwordSet', TJSONBool.Create(True));
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('switch_database',
    function: IMCPTool
    begin
      Result := TSwitchDatabaseTool.Create;
    end
  );

end.
