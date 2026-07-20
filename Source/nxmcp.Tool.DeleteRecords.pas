unit nxmcp.Tool.DeleteRecords;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the delete_records tool
  /// </summary>
  TDeleteRecordsParams = class
  private
    FTableName: string;
    FWhereClause: string;
  public
    [SchemaDescription('Name of the table to delete from')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('WHERE clause without the WHERE keyword (e.g., "ID = 5" or "Status = ''Inactive''")')]
    property WhereClause: string read FWhereClause write FWhereClause;
  end;

  /// <summary>
  /// MCP Tool that deletes records from a table
  /// </summary>
  TDeleteRecordsTool = class(TMCPToolBase<TDeleteRecordsParams>)
  protected
    function ExecuteWithParams(const Params: TDeleteRecordsParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  MCPServer.Registration,
  dmnx;

{ TDeleteRecordsTool }

constructor TDeleteRecordsTool.Create;
begin
  inherited;
  FName := 'delete_records';
  FTitle := 'Delete Records';
  FDescription := 'Delete records from a table matching the WHERE clause. WHERE clause is required for safety.';
end;

function TDeleteRecordsTool.ExecuteWithParams(const Params: TDeleteRecordsParams): string;
var
  LResultObj: TJSONObject;
  LSql: string;
  LRowsAffected: Integer;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.WhereClause) = '' then
    raise Exception.Create('WHERE clause is required to prevent accidental mass deletion');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Build DELETE SQL
  LSql := 'DELETE FROM "' + Params.TableName + '" WHERE ' + Params.WhereClause;

  // Execute (auto-reconnects and retries once on lost connection;
  // DELETE with the same WHERE clause is safe to repeat)
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      nxmodule.nxQuery1.Close;
      nxmodule.nxQuery1.SQL.Text := LSql;
      nxmodule.nxQuery1.ExecSQL;
    end);
  LRowsAffected := nxmodule.nxQuery1.RowsAffected;

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('rowsAffected', TJSONNumber.Create(LRowsAffected));
    LResultObj.AddPair('tableName', Params.TableName);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('delete_records',
    function: IMCPTool
    begin
      Result := TDeleteRecordsTool.Create;
    end
  );

end.
