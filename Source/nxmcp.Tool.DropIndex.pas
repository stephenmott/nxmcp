unit nxmcp.Tool.DropIndex;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the drop_index tool
  /// </summary>
  TDropIndexParams = class
  private
    FTableName: string;
    FIndexName: string;
  public
    [SchemaDescription('Name of the table containing the index')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the index to drop')]
    property IndexName: string read FIndexName write FIndexName;
  end;

  /// <summary>
  /// MCP Tool that drops an index from a table
  /// </summary>
  TDropIndexTool = class(TMCPToolBase<TDropIndexParams>)
  protected
    function ExecuteWithParams(const Params: TDropIndexParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  nxmcp.SqlUtils,
  dmnx;

{ TDropIndexTool }

constructor TDropIndexTool.Create;
begin
  inherited;
  FName := 'drop_index';
  FTitle := 'Drop Index';
  FDescription := 'Remove an index from a table.';
end;

function TDropIndexTool.ExecuteWithParams(const Params: TDropIndexParams): string;
var
  LResultObj: TJSONObject;
begin
  // Both are concatenated into the DROP INDEX statement below.
  CheckTableName(Params.TableName);
  CheckIdentifier(Params.IndexName, 'index name');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Drop index using SQL (NexusDB syntax: DROP INDEX tablename.indexname)
  // DDL is deliberately never replayed after an ambiguous failure.
  nxmodule.ExecuteWithoutRetry(
    procedure
    begin
      nxmodule.nxSession1.CloseInactiveTables;
      nxmodule.nxQuery1.Close;
      nxmodule.nxQuery1.SQL.Text := 'DROP INDEX "' + Params.TableName + '"."' + Params.IndexName + '"';
      nxmodule.nxQuery1.ExecSQL;
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('indexName', Params.IndexName);
    LResultObj.AddPair('message', 'Index dropped successfully');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('drop_index',
    function: IMCPTool
    begin
      Result := TDropIndexTool.Create;
    end
  );

end.
