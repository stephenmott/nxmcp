unit nxmcp.Tool.CreateTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the create_table tool
  /// </summary>
  TCreateTableParams = class
  private
    FTableName: string;
    FColumns: string;
    FDescription: string;
  public
    [SchemaDescription('Name of the table to create')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('JSON array of column definitions. Each object: {"name": "ID", "type": "AutoInc"}. ' +
      'Optional per-column keys: "size" (int, for string types), "required" (bool, NOT NULL), ' +
      '"description" (string), and "default" (object: {"type":"CurrentDateTime|CurrentUser|Constant|none", ' +
      '"constantValue":"...", "applyAt":"client|server|both", "applyOnInsert":true, "applyOnModify":false, ' +
      '"overwriteNonNull":false}). ' +
      'Supported types: Boolean, Char, WideChar, Byte, Word, Word32, Int8, Int16, Integer, Int64, AutoInc, ' +
      'Single, Float, Extended, Currency, Date, Time, DateTime, Blob, Memo, Graphic, ByteArray, ShortString, ' +
      'NullString, WideString, RecRev, Guid, BCD, WideMemo, FmtBCD, RefNr')]
    property Columns: string read FColumns write FColumns;

    [Optional]
    [SchemaDescription('Optional description (comment) for the new table')]
    property Description: string read FDescription write FDescription;
  end;

  /// <summary>
  /// MCP Tool that creates a new table
  /// </summary>
  TCreateTableTool = class(TMCPToolBase<TCreateTableParams>)
  protected
    function ExecuteWithParams(const Params: TCreateTableParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.Generics.Collections,
  Data.DB,
  nxsdTypes,
  nxsdDataDictionary,
  nxsdTableMapperDescriptor,
  nxsdServerEngine,
  nxllException,
  MCPServer.Registration,
  dmnx,
  nxmcp.FieldTypes,
  nxmcp.ColumnSpec;

{ TCreateTableTool }

constructor TCreateTableTool.Create;
begin
  inherited;
  FName := 'create_table';
  FTitle := 'Create Table';
  FDescription := 'Create a new table with the specified columns. Each column may declare a type, size, ' +
    'required (NOT NULL) flag, description, and a default value. Pass column definitions as a JSON array.';
end;

// Sets the table-level description via a restructure after the table exists,
// since a fresh dictionary has no file descriptor until the table is created.
procedure ApplyTableDescription(const ATableName, ADescription: string);
var
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
begin
  try
  nxmodule.nxSession1.CloseInactiveTables;

  LOldDict := TnxDataDictionary.Create;
  try
    nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(ATableName, nxmodule.TablePassword, LOldDict));

    LNewDict := TnxDataDictionary.Create;
    try
      LNewDict.Assign(LOldDict);
      LNewDict.FilesDescriptor.FileDescriptor[0].Desc := ADescription;

      if LOldDict.IsEqual(LNewDict) then
        Exit;

      LMapper := TnxTableMapperDescriptor.Create;
      try
        LMapper.MapAllTablesAndFieldsByName(LOldDict, LNewDict);

        nxCheck(nxmodule.nxDatabase1.RestructureTableEx(ATableName, nxmodule.TablePassword,
          LNewDict, LMapper, LTaskInfo));

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
      finally
        LMapper.Free;
      end;
    finally
      LNewDict.Free;
    end;
  finally
    LOldDict.Free;
  end;
  except
    on E: Exception do
    begin
      nxmodule.RecoverSessionAfterError(E);
      raise;
    end;
  end;
end;

function TCreateTableTool.ExecuteWithParams(const Params: TCreateTableParams): string;
var
  LResultObj: TJSONObject;
  LColumnsArr: TJSONArray;
  LColObj: TJSONObject;
  LDict: TnxDataDictionary;
  LColName, LColType: string;
  LColSize: Integer;
  LFieldType: TnxFieldType;
  LField: TnxFieldDescriptor;
  I: Integer;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.Columns) = '' then
    raise Exception.Create('Columns definition cannot be empty');

  // Parse columns JSON
  LColumnsArr := TJSONObject.ParseJSONValue(Params.Columns) as TJSONArray;
  if not Assigned(LColumnsArr) then
    raise Exception.Create('Invalid columns JSON format - expected array');

  try
    if LColumnsArr.Count = 0 then
      raise Exception.Create('At least one column is required');

    // Check connection
    if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
      raise Exception.Create('Not connected to NexusDB');

    // Create data dictionary
    LDict := TnxDataDictionary.Create;
    try
      // Add columns
      for I := 0 to LColumnsArr.Count - 1 do
      begin
        LColObj := LColumnsArr.Items[I] as TJSONObject;
        if not Assigned(LColObj) then
          raise Exception.CreateFmt('Column %d is not a valid JSON object', [I]);

        // Get column name
        if not Assigned(LColObj.GetValue('name')) then
          raise Exception.CreateFmt('Column %d missing "name" property', [I]);
        LColName := LColObj.GetValue('name').Value;

        // Get column type
        if not Assigned(LColObj.GetValue('type')) then
          raise Exception.CreateFmt('Column %d missing "type" property', [I]);
        LColType := LColObj.GetValue('type').Value;
        LFieldType := StringToFieldType(LColType);

        // Get column size (optional, default 0)
        LColSize := 0;
        if Assigned(LColObj.GetValue('size')) then
          LColSize := StrToIntDef(LColObj.GetValue('size').Value, 0);

        // Add field to dictionary
        LField := LDict.FieldsDescriptor.AddField(LColName, '', LFieldType, LColSize, 0, False);

        // Apply optional metadata: description, required, default
        ApplyColumnMetadataFromJSON(LField, LColObj);
      end;

      // Reconcile field setup/offsets after any required-flag changes
      LDict.FieldsDescriptor.UpdateSetupAndOffsets;

      // Creating a table is deliberately never replayed after an ambiguous
      // transport failure.
      nxmodule.ExecuteWithoutRetry(
        procedure
        begin
          nxmodule.nxDatabase1.CreateTable(False, Params.TableName, '', LDict);
        end);

      // Apply table-level description if requested (needs the table to exist)
      if Trim(Params.Description) <> '' then
        ApplyTableDescription(Params.TableName, Params.Description);

      // Build result
      LResultObj := TJSONObject.Create;
      try
        LResultObj.AddPair('success', TJSONBool.Create(True));
        LResultObj.AddPair('tableName', Params.TableName);
        LResultObj.AddPair('columnCount', TJSONNumber.Create(LColumnsArr.Count));
        Result := LResultObj.ToJSON;
      finally
        LResultObj.Free;
      end;
    finally
      LDict.Free;
    end;
  finally
    LColumnsArr.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('create_table',
    function: IMCPTool
    begin
      Result := TCreateTableTool.Create;
    end
  );

end.
