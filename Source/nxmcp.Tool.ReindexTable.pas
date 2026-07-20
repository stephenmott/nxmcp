unit nxmcp.Tool.ReindexTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the reindex_table tool
  /// </summary>
  TReindexTableParams = class
  private
    FTableName: string;
    FIndexName: string;
  public
    [SchemaDescription('Name of the table containing the index')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the index to rebuild')]
    property IndexName: string read FIndexName write FIndexName;
  end;

  /// <summary>
  /// MCP Tool that rebuilds an index on a table
  /// </summary>
  TReindexTableTool = class(TMCPToolBase<TReindexTableParams>)
  protected
    function ExecuteWithParams(const Params: TReindexTableParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdServerEngine,
  nxllException,
  nxsdTypes,
  MCPServer.Registration,
  dmnx;

{ TReindexTableTool }

constructor TReindexTableTool.Create;
begin
  inherited;
  FName := 'reindex_table';
  FTitle := 'Reindex Table';
  FDescription := 'Rebuild an index on a table. Use this to repair or optimize an index.';
end;

function TReindexTableTool.ExecuteWithParams(const Params: TReindexTableParams): string;
var
  LResultObj: TJSONObject;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.IndexName) = '' then
    raise Exception.Create('Index name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Close any open tables to avoid conflicts
  nxmodule.nxSession1.CloseInactiveTables;

  // Start reindex operation
  nxCheck(nxmodule.nxDatabase1.ReIndexTableEx(Params.TableName, nxmodule.TablePassword,
    Params.IndexName, LTaskInfo));

  // Wait for completion
  if Assigned(LTaskInfo) then
  try
    while True do
    begin
      LTaskInfo.GetStatus(LCompleted, LTaskStatus);
      if LCompleted then
        Break;
      Sleep(100);
    end;
    nxCheck(LTaskStatus.tsErrorCode);
  finally
    LTaskInfo.Free;
  end;

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('indexName', Params.IndexName);
    LResultObj.AddPair('recordsProcessed', TJSONNumber.Create(LTaskStatus.tsRecsRead));
    LResultObj.AddPair('message', 'Index rebuilt successfully');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('reindex_table',
    function: IMCPTool
    begin
      Result := TReindexTableTool.Create;
    end
  );

end.
