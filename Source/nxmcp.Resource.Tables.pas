unit nxmcp.Resource.Tables;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Resource.Base;

type
  /// <summary>
  /// Data class for table list - uses TJSONArray for proper serialization
  /// </summary>
  TTablesListData = class
  private
    FTables: TJSONArray;
    FCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    property Tables: TJSONArray read FTables;
    property Count: Integer read FCount write FCount;
  end;

  /// <summary>
  /// MCP Resource that lists all tables in the database
  /// URI: nexusdb://tables
  /// </summary>
  TTablesListResource = class(TMCPResourceBase<TTablesListData>)
  protected
    function GetResourceData: TTablesListData; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  MCPServer.Registration,
  dmnx;

{ TTablesListData }

constructor TTablesListData.Create;
begin
  inherited;
  FTables := TJSONArray.Create;
end;

destructor TTablesListData.Destroy;
begin
  FTables.Free;
  inherited;
end;

{ TTablesListResource }

constructor TTablesListResource.Create;
begin
  inherited;
  FURI := 'nexusdb://tables';
  FName := 'nexusdb_tables';
  FDescription := 'List of all tables in the NexusDB database';
  FMimeType := 'application/json';
end;

function TTablesListResource.GetResourceData: TTablesListData;
var
  LTableName: string;
  LField: TField;
begin
  Result := TTablesListData.Create;
  try
    if Assigned(nxmodule) and nxmodule.EnsureConnection then
    begin
      // Query system table for table list (auto-reconnects and retries once on lost connection)
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          nxmodule.nxQuery1.Close;
          nxmodule.nxQuery1.SQL.Text := 'SELECT * FROM #tables';
          nxmodule.nxQuery1.Open;
        end);
      try
        // Find the tableName field (case-insensitive search)
        LField := nil;
        for var I := 0 to nxmodule.nxQuery1.FieldCount - 1 do
        begin
          if SameText(nxmodule.nxQuery1.Fields[I].FieldName, 'tableName') or
             SameText(nxmodule.nxQuery1.Fields[I].FieldName, 'TABLE_NAME') or
             SameText(nxmodule.nxQuery1.Fields[I].FieldName, 'Name') then
          begin
            LField := nxmodule.nxQuery1.Fields[I];
            Break;
          end;
        end;

        // Fallback to second field if not found (first is usually index)
        if LField = nil then
          LField := nxmodule.nxQuery1.Fields[1];

        while not nxmodule.nxQuery1.Eof do
        begin
          LTableName := LField.AsString;
          // Skip system tables (those starting with #)
          if (LTableName <> '') and not LTableName.StartsWith('#') then
            Result.FTables.Add(LTableName);
          nxmodule.nxQuery1.Next;
        end;
      finally
        nxmodule.nxQuery1.Close;
      end;
    end;

    Result.Count := Result.FTables.Count;
  except
    Result.Free;
    raise;
  end;
end;

initialization
  TMCPRegistry.RegisterResource('nexusdb://tables',
    function: IMCPResource
    begin
      Result := TTablesListResource.Create;
    end
  );

end.
