unit nxmcp.Resource.Schema;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Resource.Base;

type
  /// <summary>
  /// Data class for database schema overview - uses TJSONArray for proper serialization
  /// </summary>
  TSchemaOverviewData = class
  private
    FDatabaseAlias: string;
    FConnected: Boolean;
    FTableCount: Integer;
    FTables: TJSONArray;
  public
    constructor Create;
    destructor Destroy; override;
    property DatabaseAlias: string read FDatabaseAlias write FDatabaseAlias;
    property Connected: Boolean read FConnected write FConnected;
    property TableCount: Integer read FTableCount write FTableCount;
    property Tables: TJSONArray read FTables;
  end;

  /// <summary>
  /// MCP Resource that provides database schema overview
  /// URI: nexusdb://schema
  /// </summary>
  TSchemaOverviewResource = class(TMCPResourceBase<TSchemaOverviewData>)
  protected
    function GetResourceData: TSchemaOverviewData; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  MCPServer.Registration,
  dmnx;

{ TSchemaOverviewData }

constructor TSchemaOverviewData.Create;
begin
  inherited;
  FTables := TJSONArray.Create;
end;

destructor TSchemaOverviewData.Destroy;
begin
  FTables.Free;
  inherited;
end;

{ TSchemaOverviewResource }

constructor TSchemaOverviewResource.Create;
begin
  inherited;
  FURI := 'nexusdb://schema';
  FName := 'nexusdb_schema';
  FDescription := 'Database schema overview including table list with column counts';
  FMimeType := 'application/json';
end;

function TSchemaOverviewResource.GetResourceData: TSchemaOverviewData;
var
  LData: TSchemaOverviewData;
  LTableName: string;
  LField: TField;
  LTableObj: TJSONObject;
begin
  LData := TSchemaOverviewData.Create;
  Result := LData;
  try
    if Assigned(nxmodule) and nxmodule.EnsureConnection then
    begin
      Result.Connected := True;
      // Show the alias name, or the server-side path when connected by path.
      if nxmodule.AliasName <> '' then
        Result.DatabaseAlias := nxmodule.AliasName
      else
        Result.DatabaseAlias := nxmodule.AliasPath;

      // Keep the complete cursor round-trip in one retryable action.  In
      // particular, field access and iteration can be the first operation to
      // report a dead NexusDB connection after Open succeeded.
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          // A retry starts with a clean payload; discard rows from the failed
          // attempt before rebuilding the cursor on the fresh session.
          while LData.FTables.Count > 0 do
            LData.FTables.Remove(LData.FTables.Count - 1).Free;
          LField := nil;
          nxmodule.nxQuery1.Close;
          try
            nxmodule.nxQuery1.SQL.Text := 'SELECT * FROM #tables';
            nxmodule.nxQuery1.Open;

            // Find the tableName field
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
            if LField = nil then
              LField := nxmodule.nxQuery1.Fields[1];

            while not nxmodule.nxQuery1.Eof do
            begin
              LTableName := LField.AsString;
              // Skip system tables
              if (LTableName <> '') and not LTableName.StartsWith('#') then
              begin
                LTableObj := TJSONObject.Create;
                LTableObj.AddPair('name', LTableName);
                LTableObj.AddPair('columnCount', TJSONNumber.Create(-1)); // Use get_table_schema for details
                LData.FTables.AddElement(LTableObj);
              end;
              nxmodule.nxQuery1.Next;
            end;
          finally
            nxmodule.nxQuery1.Close;
          end;
        end);
    end
    else
    begin
      Result.Connected := False;
      Result.DatabaseAlias := '';
    end;

    LData.TableCount := LData.FTables.Count;
  except
    Result.Free;
    raise;
  end;
end;

initialization
  TMCPRegistry.RegisterResource('nexusdb://schema',
    function: IMCPResource
    begin
      Result := TSchemaOverviewResource.Create;
    end
  );

end.
