unit nxmcp.Tool.PackTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the pack_table tool
  /// </summary>
  TPackTableParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to pack/compact')]
    property TableName: string read FTableName write FTableName;
  end;

  /// <summary>
  /// MCP Tool that packs/compacts a table to reclaim deleted space
  /// </summary>
  TPackTableTool = class(TMCPToolBase<TPackTableParams>)
  protected
    function ExecuteWithParams(const Params: TPackTableParams): string; override;
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

{ TPackTableTool }

constructor TPackTableTool.Create;
begin
  inherited;
  FName := 'pack_table';
  FTitle := 'Pack Table';
  FDescription := 'Compact a table to reclaim space from deleted records. Creates a new table and copies records over.';
end;

function TPackTableTool.ExecuteWithParams(const Params: TPackTableParams): string;
var
  LResultObj: TJSONObject;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  nxmodule.ExecuteWithoutRetry(
    procedure
    begin
      // Close any open tables to avoid conflicts
      nxmodule.nxSession1.CloseInactiveTables;

      // Start pack operation
      nxCheck(nxmodule.nxDatabase1.PackTableEx(Params.TableName,
        nxmodule.TablePassword, LTaskInfo));

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
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('recordsProcessed', TJSONNumber.Create(LTaskStatus.tsRecsWritten));
    LResultObj.AddPair('message', 'Table packed successfully');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('pack_table',
    function: IMCPTool
    begin
      Result := TPackTableTool.Create;
    end
  );

end.
