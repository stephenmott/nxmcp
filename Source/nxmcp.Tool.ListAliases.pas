unit nxmcp.Tool.ListAliases;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the list_aliases tool (no parameters needed)
  /// </summary>
  TListAliasesParams = class
  end;

  /// <summary>
  /// MCP Tool that lists all available database aliases on the NexusDB server
  /// </summary>
  TListAliasesTool = class(TMCPToolBase<TListAliasesParams>)
  protected
    function ExecuteWithParams(const Params: TListAliasesParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.Classes,
  MCPServer.Registration,
  dmnx;

{ TListAliasesTool }

constructor TListAliasesTool.Create;
begin
  inherited;
  FName := 'list_aliases';
  FTitle := 'List Database Aliases';
  FDescription := 'List all available database aliases on the connected NexusDB server. ' +
                  'Shows the current active alias and the default alias from configuration. ' +
                  'When the connection uses a direct server-side path instead of an alias, ' +
                  'currentAlias is empty and currentAliasPath holds the path.';
end;

function TListAliasesTool.ExecuteWithParams(const Params: TListAliasesParams): string;
var
  LResultObj: TJSONObject;
  LAliasesArray: TJSONArray;
  LAliasList: TStringList;
  I: Integer;
begin
  // Check that nxmodule is assigned
  if not Assigned(nxmodule) then
    raise Exception.Create('NexusDB module not initialized');

  // Embedded mode has no server-side aliases; report the mode and current path only.
  if nxmodule.IsEmbedded then
  begin
    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('mode', 'Embedded');
      LResultObj.AddPair('message',
        'Embedded (in-process) mode has no server aliases; databases are opened by path.');
      LResultObj.AddPair('aliasCount', TJSONNumber.Create(0));
      LResultObj.AddPair('aliases', TJSONArray.Create);
      LResultObj.AddPair('currentAlias', nxmodule.AliasName);
      LResultObj.AddPair('currentAliasPath', nxmodule.AliasPath);
      LResultObj.AddPair('defaultAliasPath', nxmodule.DefaultAliasPath);
      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
    Exit;
  end;

  // Listing aliases needs a live session, not an open database - EnsureSession
  // rather than EnsureConnection, so the aliases can still be listed when the
  // current database will not open, which is exactly when you need to see them.
  if not nxmodule.EnsureSession then
    raise Exception.Create('Not connected to NexusDB server: ' + nxmodule.GetLastError);

  // A session whose socket died still reports Active; only the round-trip below
  // finds out, so it has to be able to reconnect and retry.
  LAliasList := nil;
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      LAliasList := nxmodule.GetAliasNames;
    end);
  try
    LAliasesArray := TJSONArray.Create;
    for I := 0 to LAliasList.Count - 1 do
      LAliasesArray.Add(LAliasList[I]);

    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('mode', 'Remote');
      LResultObj.AddPair('aliasCount', TJSONNumber.Create(LAliasList.Count));
      LResultObj.AddPair('aliases', LAliasesArray);
      LResultObj.AddPair('currentAlias', nxmodule.AliasName);
      LResultObj.AddPair('currentAliasPath', nxmodule.AliasPath);
      LResultObj.AddPair('defaultAlias', nxmodule.DefaultAliasName);
      LResultObj.AddPair('defaultAliasPath', nxmodule.DefaultAliasPath);
      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
  finally
    LAliasList.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('list_aliases',
    function: IMCPTool
    begin
      Result := TListAliasesTool.Create;
    end
  );

end.
