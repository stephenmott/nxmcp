unit nxmcp.Tool.InsertRecord;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the insert_record tool
  /// </summary>
  TInsertRecordParams = class
  private
    FTableName: string;
    FData: string;
  public
    [SchemaDescription('Name of the table to insert into')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('JSON string with column names as keys and values to insert, e.g. {"Name": "Test", "Value": 123}. ' +
      'GUID, Date, Time and DateTime columns are handled automatically from plain strings: GUID (braces optional) e.g. "{1111...}"; ' +
      'Date "YYYY-MM-DD"; Time "HH:MM:SS"; DateTime "YYYY-MM-DD HH:MM:SS" (ISO "T" separator and a trailing Z/offset are also accepted).')]
    property Data: string read FData write FData;
  end;

  /// <summary>
  /// MCP Tool that inserts a record into a table
  /// </summary>
  TInsertRecordTool = class(TMCPToolBase<TInsertRecordParams>)
  protected
    function ExecuteWithParams(const Params: TInsertRecordParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  System.Generics.Collections,
  nxsdTypes,
  MCPServer.Registration,
  nxmcp.SqlUtils,
  dmnx,
  nxmcp.ValueFormat;

{ TInsertRecordTool }

constructor TInsertRecordTool.Create;
begin
  inherited;
  FName := 'insert_record';
  FTitle := 'Insert Record';
  FDescription := 'Insert a new record into a table. Pass column values as a JSON object.';
end;

function TInsertRecordTool.ExecuteWithParams(const Params: TInsertRecordParams): string;
var
  LResultObj: TJSONObject;
  LDataObj: TJSONObject;
  LSql: string;
  LColumns: string;
  LValues: string;
  LPair: TJSONPair;
  LRowsAffected: Integer;
  LFieldTypes: TDictionary<string, TnxFieldType>;
begin
  // Validate parameters
  CheckTableName(Params.TableName);

  if Trim(Params.Data) = '' then
    raise Exception.Create('Data cannot be empty');

  // Parse JSON data
  LDataObj := TJSONObject.ParseJSONValue(Params.Data) as TJSONObject;
  if not Assigned(LDataObj) then
    raise Exception.Create('Invalid JSON data format');

  try
    if LDataObj.Count = 0 then
      raise Exception.Create('Data object cannot be empty');

    // Check connection
    if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
      raise Exception.Create('Not connected to NexusDB');

    // Look up column types so GUID (and other typed) columns are formatted
    // correctly. Non-fatal: if the dictionary can't be read, fall back to
    // plain literal formatting (old behaviour) rather than failing the insert.
    try
      LFieldTypes := GetTableFieldTypes(Params.TableName);
    except
      LFieldTypes := nil;
    end;

    try
      // Build INSERT SQL
      LColumns := '';
      LValues := '';

      for LPair in LDataObj do
      begin
        if LColumns <> '' then
        begin
          LColumns := LColumns + ', ';
          LValues := LValues + ', ';
        end;

        // The JSON key becomes a quoted column name in the SQL - validate it the
        // same way as the table name.
        CheckIdentifier(LPair.JsonString.Value, 'column name');

        LColumns := LColumns + '"' + LPair.JsonString.Value + '"';
        LValues := LValues +
          FormatJsonValueAsSql(LPair.JsonString.Value, LPair.JsonValue, LFieldTypes);
      end;
    finally
      LFieldTypes.Free;
    end;

    LSql := 'INSERT INTO "' + Params.TableName + '" (' + LColumns + ') VALUES (' + LValues + ')';

    // Execute (auto-reconnects and retries once on lost connection;
    // note: retry on comm-lost after server commit can produce a duplicate row)
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
  finally
    LDataObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('insert_record',
    function: IMCPTool
    begin
      Result := TInsertRecordTool.Create;
    end
  );

end.
