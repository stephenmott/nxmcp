unit nxmcp.Tool.RecoverTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the recover_table tool
  /// </summary>
  TRecoverTableParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to recover')]
    property TableName: string read FTableName write FTableName;
  end;

  /// <summary>
  /// MCP Tool that attempts to recover records from a broken table
  /// </summary>
  TRecoverTableTool = class(TMCPToolBase<TRecoverTableParams>)
  protected
    function ExecuteWithParams(const Params: TRecoverTableParams): string; override;
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

{ TRecoverTableTool }

constructor TRecoverTableTool.Create;
begin
  inherited;
  FName := 'recover_table';
  FTitle := 'Recover Table';
  FDescription := 'Attempt to recover records from a broken/corrupted table. Recovered records are placed in TableName_Recovered, unrecoverable records in TableName_Failed.';
end;

function TRecoverTableTool.ExecuteWithParams(const Params: TRecoverTableParams): string;
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

      // Start recover operation
      nxCheck(nxmodule.nxDatabase1.RecoverTableEx(Params.TableName,
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
    LResultObj.AddPair('recoveredTableName', Params.TableName + '_Recovered');
    LResultObj.AddPair('failedTableName', Params.TableName + '_Failed');
    LResultObj.AddPair('recordsRead', TJSONNumber.Create(LTaskStatus.tsRecsRead));
    LResultObj.AddPair('recordsRecovered', TJSONNumber.Create(LTaskStatus.tsRecsWritten));
    LResultObj.AddPair('message', 'Table recovery completed');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('recover_table',
    function: IMCPTool
    begin
      Result := TRecoverTableTool.Create;
    end
  );

end.
