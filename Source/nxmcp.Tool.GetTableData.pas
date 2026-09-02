unit nxmcp.Tool.GetTableData;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Math,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the get_table_data tool
  /// </summary>
  TGetTableDataParams = class
  private
    FTableName: string;
    FMaxRows: Integer;
    FOffset: Integer;
    FOrderBy: string;
  public
    [SchemaDescription('Name of the table to retrieve data from')]
    property TableName: string read FTableName write FTableName;

    [Optional]
    [SchemaDescription('Maximum number of rows to return (default: 100, max: 1000)')]
    property MaxRows: Integer read FMaxRows write FMaxRows;

    [Optional]
    [SchemaDescription('Number of rows to skip (for pagination, default: 0)')]
    property Offset: Integer read FOffset write FOffset;

    [Optional]
    [SchemaDescription('Column name to order by (optional)')]
    property OrderBy: string read FOrderBy write FOrderBy;
  end;

  /// <summary>
  /// MCP Tool that retrieves data from a table with pagination support
  /// </summary>
  TGetTableDataTool = class(TMCPToolBase<TGetTableDataParams>)
  protected
    function ExecuteWithParams(const Params: TGetTableDataParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  DataSet.Serialize,
  MCPServer.Registration,
  nxmcp.SqlUtils,
  dmnx;

{ TGetTableDataTool }

constructor TGetTableDataTool.Create;
begin
  inherited;
  FName := 'get_table_data';
  FTitle := 'Get Table Data';
  FDescription := 'Retrieve data from a table with pagination support. Returns rows as JSON array.';
end;

function TGetTableDataTool.ExecuteWithParams(const Params: TGetTableDataParams): string;
var
  LResult: string;
  LResultObj: TJSONObject;
  LJSONArray: TJSONArray;
  LMaxRows: Integer;
  LOffset: Integer;
  LSql: string;
  LRowCount: Integer;
begin
  // The names are concatenated into the SQL below, and NexusDB has no escape for
  // a quote inside a quoted identifier - so validate against the engine's own
  // rules instead. '"' and ';' are not legal identifier characters, which is what
  // stops a crafted name from closing the quote and appending a second statement.
  CheckTableName(Params.TableName);
  if Trim(Params.OrderBy) <> '' then
    CheckIdentifier(Params.OrderBy, 'orderBy column');

  // Determine limits
  if Params.MaxRows > 0 then
    LMaxRows := Min(Params.MaxRows, 1000)
  else
    LMaxRows := 100;

  LOffset := Max(0, Params.Offset);

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Build SQL query
  LSql := 'SELECT * FROM "' + Params.TableName + '"';
  if Trim(Params.OrderBy) <> '' then
    LSql := LSql + ' ORDER BY "' + Params.OrderBy + '"';

  LResultObj := nil;
  LJSONArray := nil;
  LResult := '';

  // Keep the complete cursor round-trip in one retryable action.  Any cursor
  // operation can be the first one to report a dead NexusDB connection after
  // Open succeeded, so none of them may sit outside ExecuteWithReconnect.
  nxmodule.ExecuteWithReconnect(
    procedure
    begin
      // Reset all attempt state before rebuilding the cursor and payload.  In
      // particular, LOffset is consumed by the first pagination pass.
      LResult := '';
      LResultObj.Free;
      LResultObj := nil;
      LJSONArray.Free;
      LJSONArray := nil;
      LOffset := Max(0, Params.Offset);
      LRowCount := 0;

      nxmodule.nxQuery1.Close;
      try
        nxmodule.nxQuery1.SQL.Text := LSql;
        nxmodule.nxQuery1.Open;

        // Skip to offset
        nxmodule.nxQuery1.First;
        while (LOffset > 0) and not nxmodule.nxQuery1.Eof do
        begin
          Dec(LOffset);
          nxmodule.nxQuery1.Next;
        end;

        // Count available rows from current position
        LRowCount := 0;
        while not nxmodule.nxQuery1.Eof do
        begin
          Inc(LRowCount);
          if LRowCount >= LMaxRows then
            Break;
          nxmodule.nxQuery1.Next;
        end;

        // Reset to offset position and export
        nxmodule.nxQuery1.First;
        LOffset := Max(0, Params.Offset);
        while (LOffset > 0) and not nxmodule.nxQuery1.Eof do
        begin
          Dec(LOffset);
          nxmodule.nxQuery1.Next;
        end;

        // Build JSON array manually with limit
        LJSONArray := TJSONArray.Create;
        try
          LRowCount := 0;
          while not nxmodule.nxQuery1.Eof do
          begin
            if LRowCount >= LMaxRows then
              Break;
            LJSONArray.AddElement(nxmodule.nxQuery1.ToJSONObject);
            Inc(LRowCount);
            nxmodule.nxQuery1.Next;
          end;

          // Build result
          LResultObj := TJSONObject.Create;
          try
            LResultObj.AddPair('tableName', Params.TableName);
            LResultObj.AddPair('rowCount', TJSONNumber.Create(LRowCount));
            LResultObj.AddPair('maxRows', TJSONNumber.Create(LMaxRows));
            LResultObj.AddPair('offset', TJSONNumber.Create(Max(0, Params.Offset)));
            LResultObj.AddPair('hasMore', TJSONBool.Create(not nxmodule.nxQuery1.Eof));
            LResultObj.AddPair('data', LJSONArray);
            // Ownership of the array now belongs to the object.
            LJSONArray := nil;
            LResult := LResultObj.ToJSON;
          finally
            LResultObj.Free;
            LResultObj := nil;
          end;
        finally
          LJSONArray.Free;
          LJSONArray := nil;
        end;
      finally
        nxmodule.nxQuery1.Close;
      end;
    end);
  Result := LResult;
end;

initialization
  TMCPRegistry.RegisterTool('get_table_data',
    function: IMCPTool
    begin
      Result := TGetTableDataTool.Create;
    end
  );

end.
