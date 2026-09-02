unit nxmcp.Tool.ListTables;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TListTablesParams = class
  end;

  TListTablesTool = class(TMCPToolBase<TListTablesParams>)
  protected
    function ExecuteWithParams(const Params: TListTablesParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  MCPServer.Registration,
  dmnx;

{ TListTablesTool }

constructor TListTablesTool.Create;
begin
  inherited;
  FName := 'list_tables';
  FTitle := 'List Tables';
  FDescription := 'List all user tables in the connected NexusDB database.';
end;

function TListTablesTool.ExecuteWithParams(const Params: TListTablesParams): string;
var
  LResultObj: TJSONObject;
  LTables: TJSONArray;
  LTarget: string;
begin
  // Transparently reconnects if the session dropped since the last call.
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  LTables := TJSONArray.Create;
  try
    // A pure read of the #TABLES meta table: replaying it on a fresh session
    // after communication loss / re-entry is safe, so the retry-enabled
    // boundary applies. Open, traverse and close inside one action so a retry
    // rebuilds the whole list rather than resuming a dead cursor.
    nxmodule.ExecuteWithReconnect(
      procedure
      var
        LField: TField;
        LTableName: string;
        I: Integer;
      begin
        // Discard anything a failed first attempt collected.
        while LTables.Count > 0 do
          LTables.Remove(LTables.Count - 1).Free;

        nxmodule.nxQuery1.Close;
        nxmodule.nxQuery1.Params.Clear;
        nxmodule.nxQuery1.SQL.Text := 'SELECT * FROM #tables';
        nxmodule.nxQuery1.Open;
        try
          LField := nil;
          for I := 0 to nxmodule.nxQuery1.FieldCount - 1 do
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
            if (LTableName <> '') and not LTableName.StartsWith('#') then
              LTables.Add(LTableName);
            nxmodule.nxQuery1.Next;
          end;
        finally
          nxmodule.nxQuery1.Close;
        end;
      end);

    if nxmodule.AliasPath <> '' then
      LTarget := nxmodule.AliasPath
    else
      LTarget := nxmodule.AliasName;

    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('database', LTarget);
      LResultObj.AddPair('tables', LTables.Clone as TJSONArray);
      LResultObj.AddPair('count', TJSONNumber.Create(LTables.Count));
      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
  finally
    LTables.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('list_tables',
    function: IMCPTool
    begin
      Result := TListTablesTool.Create;
    end
  );

end.
