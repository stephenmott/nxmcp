unit nxmcp.Tool.RenameTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  /// <summary>
  /// Parameters for the rename_table tool
  /// </summary>
  TRenameTableParams = class
  private
    FOldName: string;
    FNewName: string;
  public
    [SchemaDescription('Current name of the table')]
    property OldName: string read FOldName write FOldName;

    [SchemaDescription('New name for the table')]
    property NewName: string read FNewName write FNewName;
  end;

  /// <summary>
  /// MCP Tool that renames a table
  /// </summary>
  TRenameTableTool = class(TSerializedToolBase<TRenameTableParams>)
  protected
    function ExecuteWithParams(const Params: TRenameTableParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TRenameTableTool }

constructor TRenameTableTool.Create;
begin
  inherited;
  FName := 'rename_table';
  FTitle := 'Rename Table';
  FDescription := 'Rename an existing table.';
end;

function TRenameTableTool.ExecuteWithParams(const Params: TRenameTableParams): string;
var
  LResultObj: TJSONObject;
begin
  // Validate parameters
  if Trim(Params.OldName) = '' then
    raise Exception.Create('Old table name cannot be empty');

  if Trim(Params.NewName) = '' then
    raise Exception.Create('New table name cannot be empty');

  if SameText(Params.OldName, Params.NewName) then
    raise Exception.Create('Old and new table names must be different');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Close any open tables to avoid conflicts
  nxmodule.nxSession1.CloseInactiveTables;

  // Rename using database method (auto-reconnects and retries once on lost connection)
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      nxmodule.nxDatabase1.RenameTable(Params.OldName, Params.NewName, nxmodule.TablePassword);
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('oldName', Params.OldName);
    LResultObj.AddPair('newName', Params.NewName);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('rename_table',
    function: IMCPTool
    begin
      Result := TRenameTableTool.Create;
    end
  );

end.
