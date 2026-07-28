unit nxmcp.Tool.SwitchServer;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  /// <summary>
  /// Parameters for the switch_server tool
  /// </summary>
  TSwitchServerParams = class
  private
    FMode: string;
    FServerHost: string;
    FServerPort: Integer;
    FAliasName: string;
    FAliasPath: string;
    FTablePassword: string;
  public
    [Optional]
    [SchemaDescription('Server mode: "remote" (connect to an NXserver, the default) or ' +
      '"embedded" (an in-process local NexusDB server). In embedded mode aliasPath is ' +
      'REQUIRED and serverHost/serverPort/aliasName are ignored (there are no aliases in embedded mode).')]
    property Mode: string read FMode write FMode;

    [Optional]
    [SchemaDescription('NexusDB server hostname or IP address (required for remote mode)')]
    property ServerHost: string read FServerHost write FServerHost;

    [Optional]
    [SchemaDescription('NexusDB server port (remote mode; default: keeps current port)')]
    property ServerPort: Integer read FServerPort write FServerPort;

    [Optional]
    [SchemaDescription('Database alias to open (remote mode only). ' +
      'Provide either aliasName or aliasPath, not both.')]
    property AliasName: string read FAliasName write FAliasName;

    [Optional]
    [SchemaDescription('Server-side filesystem path to the database folder (e.g. C:\Data\MyDB). ' +
      'REQUIRED in embedded mode; in remote mode provide either aliasName or aliasPath, not both.')]
    property AliasPath: string read FAliasPath write FAliasPath;

    [Optional]
    [SchemaDescription('Table password for the database (leave empty if not needed)')]
    property TablePassword: string read FTablePassword write FTablePassword;
  end;

  /// <summary>
  /// MCP Tool that switches the connection to a different NexusDB server
  /// </summary>
  TSwitchServerTool = class(TSerializedToolBase<TSwitchServerParams>)
  protected
    function ExecuteWithParams(const Params: TSwitchServerParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TSwitchServerTool }

constructor TSwitchServerTool.Create;
begin
  inherited;
  FName := 'switch_server';
  FTitle := 'Switch Server';
  FDescription := 'Switch the NexusDB server connection. mode="remote" (default) connects to ' +
                  'an NXserver; mode="embedded" runs an in-process local NexusDB server. ' +
                  'Changing mode fully disconnects and reconnects, deactivating the components ' +
                  'not in use; an embedded-to-embedded switch only changes the database folder ' +
                  'and keeps the engine and session up. ' +
                  'In remote mode optionally specify the database as EITHER aliasName (a ' +
                  'server-configured alias) OR aliasPath (a server-side filesystem path). ' +
                  'In embedded mode aliasPath is required (there are no aliases in embedded ' +
                  'mode) and must be an existing directory - a bad path is rejected up front ' +
                  'and the current connection is left untouched. ' +
                  'If switching fails, the server attempts to reconnect to the previous connection.';
end;

function TSwitchServerTool.ExecuteWithParams(const Params: TSwitchServerParams): string;
var
  LResultObj: TJSONObject;
  LOldServer: string;
  LEmbedded: Boolean;
begin
  // Check that nxmodule is assigned
  if not Assigned(nxmodule) then
    raise Exception.Create('NexusDB module not initialized');

  LEmbedded := SameText(Trim(Params.Mode), 'embedded') or
               SameText(Trim(Params.Mode), 'local');

  // Reject unknown modes instead of silently treating them as remote: a typo
  // like "embeded" would otherwise fall through and fail with a misleading
  // "Server host is required" - or worse, reconnect to the wrong target.
  if not LEmbedded and (Trim(Params.Mode) <> '') and
     not SameText(Trim(Params.Mode), 'remote') then
    raise Exception.Create('Unknown mode "' + Params.Mode +
      '" (valid values: remote, embedded)');

  // ---- Embedded mode ----
  if LEmbedded then
  begin
    if Trim(Params.AliasPath) = '' then
      raise Exception.Create('Embedded mode requires aliasPath');

    // Already running embedded on this path?
    if nxmodule.IsEmbedded and SameText(Params.AliasPath, nxmodule.AliasPath) and
       nxmodule.IsConnected then
    begin
      LResultObj := TJSONObject.Create;
      try
        LResultObj.AddPair('success', TJSONBool.Create(True));
        LResultObj.AddPair('message', 'Already connected to this embedded database');
        LResultObj.AddPair('mode', 'Embedded');
        LResultObj.AddPair('aliasPath', nxmodule.AliasPath);
        Result := LResultObj.ToJSON;
      finally
        LResultObj.Free;
      end;
      Exit;
    end;

    LOldServer := Tnxmodule.ModeToStr(nxmodule.ServerMode);
    if not nxmodule.IsEmbedded then
      LOldServer := LOldServer + ' (' + nxmodule.ServerHost + ':' +
                    IntToStr(nxmodule.ServerPort) + ')';

    // Perform the switch (SwitchToEmbedded handles rollback on failure)
    nxmodule.SwitchToEmbedded(Params.AliasPath, Params.TablePassword);

    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('success', TJSONBool.Create(True));
      LResultObj.AddPair('previousConnection', LOldServer);
      LResultObj.AddPair('mode', 'Embedded');
      LResultObj.AddPair('currentAliasPath', nxmodule.AliasPath);
      LResultObj.AddPair('connected', TJSONBool.Create(nxmodule.IsConnected));
      if Params.TablePassword <> '' then
        LResultObj.AddPair('passwordSet', TJSONBool.Create(True));
      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
    Exit;
  end;

  // ---- Remote mode ----
  if Trim(Params.ServerHost) = '' then
    raise Exception.Create('Server host is required for remote mode');

  if (Trim(Params.AliasName) <> '') and (Trim(Params.AliasPath) <> '') then
    raise Exception.Create('Provide either aliasName or aliasPath, not both');

  // Check if already connected to same remote server (and same database target)
  if (not nxmodule.IsEmbedded) and
     SameText(Params.ServerHost, nxmodule.ServerHost) and
     ((Params.ServerPort = 0) or (Params.ServerPort = nxmodule.ServerPort)) and
     ((Params.AliasName = '') or SameText(Params.AliasName, nxmodule.AliasName)) and
     ((Params.AliasPath = '') or SameText(Params.AliasPath, nxmodule.AliasPath)) and
     nxmodule.IsConnected then
  begin
    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('success', TJSONBool.Create(True));
      LResultObj.AddPair('message', 'Already connected to this server');
      LResultObj.AddPair('mode', 'Remote');
      LResultObj.AddPair('serverHost', nxmodule.ServerHost);
      LResultObj.AddPair('serverPort', TJSONNumber.Create(nxmodule.ServerPort));
      LResultObj.AddPair('aliasName', nxmodule.AliasName);
      LResultObj.AddPair('aliasPath', nxmodule.AliasPath);
      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
    Exit;
  end;

  // Remember previous connection for reporting
  if nxmodule.IsEmbedded then
    LOldServer := 'Embedded (' + nxmodule.AliasPath + ')'
  else
    LOldServer := nxmodule.ServerHost + ':' + IntToStr(nxmodule.ServerPort);

  // Perform the switch (SwitchServer handles rollback on failure)
  nxmodule.SwitchServer(Params.ServerHost, Params.ServerPort,
    Params.AliasName, Params.TablePassword, Params.AliasPath);

  // Build success result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('previousConnection', LOldServer);
    LResultObj.AddPair('mode', 'Remote');
    LResultObj.AddPair('currentServer', nxmodule.ServerHost + ':' +
                       IntToStr(nxmodule.ServerPort));
    LResultObj.AddPair('currentAlias', nxmodule.AliasName);
    LResultObj.AddPair('currentAliasPath', nxmodule.AliasPath);
    LResultObj.AddPair('connected', TJSONBool.Create(nxmodule.IsConnected));
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('switch_server',
    function: IMCPTool
    begin
      Result := TSwitchServerTool.Create;
    end
  );

end.
