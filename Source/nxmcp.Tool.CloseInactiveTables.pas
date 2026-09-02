unit nxmcp.Tool.CloseInactiveTables;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the close_inactive_tables tool (no parameters needed)
  /// </summary>
  TCloseInactiveTablesParams = class
  end;

  /// <summary>
  /// MCP Tool that releases the tables and folders the server keeps open in its
  /// cache for this session.
  /// </summary>
  TCloseInactiveTablesTool = class(TMCPToolBase<TCloseInactiveTablesParams>)
  protected
    function ExecuteWithParams(const Params: TCloseInactiveTablesParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TCloseInactiveTablesTool }

constructor TCloseInactiveTablesTool.Create;
begin
  inherited;
  FName := 'close_inactive_tables';
  FTitle := 'Close Inactive Tables and Folders';
  FDescription := 'Release the tables and folders that the NexusDB server keeps open in its cache ' +
                  'for this session (TnxSession.CloseInactiveTables + CloseInactiveFolders). ' +
                  'Use it to free server-side file handles - for example before backing up, ' +
                  'copying or replacing database files, or after a maintenance operation left ' +
                  'files locked. Only cached, no-longer-used tables are closed; tables another ' +
                  'session still has open are unaffected. In embedded mode the handles being ' +
                  'released are held by this nxmcp process itself.';
end;

function TCloseInactiveTablesTool.ExecuteWithParams(const Params: TCloseInactiveTablesParams): string;
var
  LResultObj: TJSONObject;
begin
  if not Assigned(nxmodule) then
    raise Exception.Create('NexusDB module not initialized');

  // The server cache being swept belongs to the *session*, not to the current
  // database, and releasing file handles is most useful exactly when the current
  // database will not open. EnsureSession therefore, not EnsureConnection - a
  // database that refuses to open must not block the cleanup.
  if not nxmodule.EnsureSession then
    raise Exception.Create('Not connected to NexusDB server: ' + nxmodule.GetLastError);

  // This maintenance action changes server cache state. Recover a poisoned
  // session, but never replay an operation whose first outcome is unknown.
  nxmodule.ExecuteWithoutRetry(
    procedure
    begin
      // Our own cursors count as active and would survive the sweep; close them
      // first so the tables behind them can actually be released. Every tool
      // closes its dataset when it finishes, so this is normally a no-op.
      if nxmodule.nxQuery1.Active then
        nxmodule.nxQuery1.Close;
      if nxmodule.nxTable1.Active then
        nxmodule.nxTable1.Close;

      // Tables before folders: a folder cannot be released while one of its
      // tables is still open (same order the EnterpriseManager uses).
      nxmodule.nxSession1.CloseInactiveTables;
      nxmodule.nxSession1.CloseInactiveFolders;
    end);

  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('mode', Tnxmodule.ModeToStr(nxmodule.ServerMode));
    LResultObj.AddPair('closedInactiveTables', TJSONBool.Create(True));
    LResultObj.AddPair('closedInactiveFolders', TJSONBool.Create(True));
    LResultObj.AddPair('message',
      'Released the tables and folders held open by the server cache for this session.');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('close_inactive_tables',
    function: IMCPTool
    begin
      Result := TCloseInactiveTablesTool.Create;
    end
  );

end.
