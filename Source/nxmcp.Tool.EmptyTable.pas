unit nxmcp.Tool.EmptyTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the empty_table tool
  /// </summary>
  TEmptyTableParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to empty')]
    property TableName: string read FTableName write FTableName;
  end;

  /// <summary>
  /// MCP Tool that deletes all records from a table
  /// </summary>
  TEmptyTableTool = class(TMCPToolBase<TEmptyTableParams>)
  protected
    function ExecuteWithParams(const Params: TEmptyTableParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TEmptyTableTool }

constructor TEmptyTableTool.Create;
begin
  inherited;
  FName := 'empty_table';
  FTitle := 'Empty Table';
  FDescription := 'Delete all records from a table. WARNING: This permanently removes all data but keeps the table structure.';
end;

function TEmptyTableTool.ExecuteWithParams(const Params: TEmptyTableParams): string;
var
  LResultObj: TJSONObject;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Emptying a table is deliberately never replayed after an ambiguous failure.
  nxmodule.ExecuteWithoutRetry(
    procedure
    begin
      nxmodule.nxSession1.CloseInactiveTables;
      nxmodule.nxDatabase1.EmptyTable(Params.TableName, nxmodule.TablePassword);
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('message', 'All records deleted successfully');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('empty_table',
    function: IMCPTool
    begin
      Result := TEmptyTableTool.Create;
    end
  );

end.
