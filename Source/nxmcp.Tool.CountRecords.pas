unit nxmcp.Tool.CountRecords;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the count_records tool
  /// </summary>
  TCountRecordsParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to count records in')]
    property TableName: string read FTableName write FTableName;
  end;

  /// <summary>
  /// MCP Tool that returns the record count for a table.
  /// Uses NexusDB metadata for efficient counting without scanning.
  /// </summary>
  TCountRecordsTool = class(TMCPToolBase<TCountRecordsParams>)
  protected
    function ExecuteWithParams(const Params: TCountRecordsParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  MCPServer.Registration,
  dmnx;

{ TCountRecordsTool }

constructor TCountRecordsTool.Create;
begin
  inherited;
  FName := 'count_records';
  FTitle := 'Count Table Records';
  FDescription := 'Get the record count for a table. Uses NexusDB table metadata for efficient ' +
                  'counting without scanning rows. Much faster than SELECT COUNT(*).';
end;

function TCountRecordsTool.ExecuteWithParams(const Params: TCountRecordsParams): string;
var
  LResultObj: TJSONObject;
  LRecordCount: Integer;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Open table and get record count from metadata (auto-reconnects and retries once on lost connection)
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      nxmodule.nxTable1.Close;
      nxmodule.nxTable1.TableName := Params.TableName;
      nxmodule.nxTable1.Open;
    end);
  try
    LRecordCount := nxmodule.nxTable1.RecordCount;
  finally
    nxmodule.nxTable1.Close;
  end;

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('recordCount', TJSONNumber.Create(LRecordCount));
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('count_records',
    function: IMCPTool
    begin
      Result := TCountRecordsTool.Create;
    end
  );

end.
