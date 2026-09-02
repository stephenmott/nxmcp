unit nxmcp.Tool.DropTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the drop_table tool
  /// </summary>
  TDropTableParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to delete')]
    property TableName: string read FTableName write FTableName;
  end;

  /// <summary>
  /// MCP Tool that deletes a table
  /// </summary>
  TDropTableTool = class(TMCPToolBase<TDropTableParams>)
  protected
    function ExecuteWithParams(const Params: TDropTableParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TDropTableTool }

constructor TDropTableTool.Create;
begin
  inherited;
  FName := 'drop_table';
  FTitle := 'Drop Table';
  FDescription := 'Delete a table from the database. WARNING: This permanently removes the table and all its data.';
end;

function TDropTableTool.ExecuteWithParams(const Params: TDropTableParams): string;
var
  LResultObj: TJSONObject;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Deleting a table is deliberately never replayed after an ambiguous failure.
  nxmodule.ExecuteWithoutRetry(
    procedure
    begin
      nxmodule.nxSession1.CloseInactiveTables;
      nxmodule.nxDatabase1.DeleteTable(Params.TableName, '');
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('message', 'Table deleted successfully');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('drop_table',
    function: IMCPTool
    begin
      Result := TDropTableTool.Create;
    end
  );

end.
