unit nxmcp.Tool.ModifyColumn;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the modify_column tool
  /// </summary>
  TModifyColumnParams = class
  private
    FTableName: string;
    FColumnName: string;
    FNewType: string;
    FNewSize: Integer;
    FNewName: string;
    FRequired: string;
  public
    [SchemaDescription('Name of the table containing the column')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Current name of the column to modify')]
    property ColumnName: string read FColumnName write FColumnName;

    [Optional]
    [SchemaDescription('New column type (optional): Boolean, Char, WideChar, Byte, Word, Word32, Int8, Int16, Integer, Int64, AutoInc, Single, Float, Extended, Currency, Date, Time, DateTime, Blob, Memo, Graphic, ByteArray, ShortString, NullString, WideString, RecRev, Guid, BCD, WideMemo, FmtBCD, RefNr')]
    property NewType: string read FNewType write FNewType;

    [Optional]
    [SchemaDescription('New size/length for string types (optional)')]
    property NewSize: Integer read FNewSize write FNewSize;

    [Optional]
    [SchemaDescription('New name for the column (optional, for renaming)')]
    property NewName: string read FNewName write FNewName;

    [Optional]
    [SchemaDescription('Set the required (NOT NULL) flag: "true" or "false". Leave empty to keep unchanged. Making a column required may fail if existing records hold null values.')]
    property Required: string read FRequired write FRequired;
  end;

  /// <summary>
  /// MCP Tool that modifies a column in an existing table
  /// </summary>
  TModifyColumnTool = class(TMCPToolBase<TModifyColumnParams>)
  protected
    function ExecuteWithParams(const Params: TModifyColumnParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdTypes,
  nxsdDataDictionary,
  nxsdServerEngine,
  nxsdTableMapperDescriptor,
  nxsdRecordMapperDescriptor,
  nxllException,
  MCPServer.Registration,
  dmnx,
  nxmcp.FieldTypes;

{ TModifyColumnTool }

constructor TModifyColumnTool.Create;
begin
  inherited;
  FName := 'modify_column';
  FTitle := 'Modify Column';
  FDescription := 'Modify a column in an existing table. Can change type, size, or rename the column.';
end;

function TModifyColumnTool.ExecuteWithParams(const Params: TModifyColumnParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LFieldIdx: Integer;
  LChanges: TStringList;
  LIsRename: Boolean;
  LRequired: string;
  LHasRequired: Boolean;
  LRequiredValue: Boolean;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.ColumnName) = '' then
    raise Exception.Create('Column name cannot be empty');

  // Parse the tri-state required flag ('', 'true', 'false')
  LRequired := Trim(Params.Required);
  LHasRequired := LRequired <> '';
  if LHasRequired then
  begin
    if SameText(LRequired, 'true') then
      LRequiredValue := True
    else if SameText(LRequired, 'false') then
      LRequiredValue := False
    else
      raise Exception.CreateFmt('Invalid required value "%s". Use "true", "false", or leave empty.', [Params.Required]);
  end
  else
    LRequiredValue := False;

  // Check that at least one modification is specified
  if (Trim(Params.NewType) = '') and (Params.NewSize = 0) and (Trim(Params.NewName) = '') and (not LHasRequired) then
    raise Exception.Create('At least one modification (newType, newSize, newName, or required) must be specified');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Close any open tables to avoid conflicts
  nxmodule.nxSession1.CloseInactiveTables;

  LChanges := TStringList.Create;
  try
    LIsRename := (Trim(Params.NewName) <> '') and (not SameText(Params.NewName, Params.ColumnName));

    LOldDict := TnxDataDictionary.Create;
    try
      // Get existing dictionary
      nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

      // Check if column exists
      LFieldIdx := LOldDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);
      if LFieldIdx < 0 then
        raise Exception.CreateFmt('Column "%s" not found in table "%s"', [Params.ColumnName, Params.TableName]);

      // Create new dictionary with modifications
      LNewDict := TnxDataDictionary.Create;
      try
        LNewDict.Assign(LOldDict);

        // Get field index in new dictionary
        LFieldIdx := LNewDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);

        // Apply type change
        if Trim(Params.NewType) <> '' then
        begin
          LNewDict.FieldsDescriptor.FieldDescriptor[LFieldIdx].fdType := StringToFieldType(Params.NewType);
          LChanges.Add('type=' + Params.NewType);
        end;

        // Apply size change
        if Params.NewSize > 0 then
        begin
          LNewDict.FieldsDescriptor.FieldDescriptor[LFieldIdx].fdUnits := Params.NewSize;
          LChanges.Add('size=' + IntToStr(Params.NewSize));
        end;

        // Apply required (NOT NULL) change
        if LHasRequired then
        begin
          LNewDict.FieldsDescriptor.FieldDescriptor[LFieldIdx].fdRequired := LRequiredValue;
          LChanges.Add('required=' + BoolToStr(LRequiredValue, True));
        end;

        // Recalculate offsets after any type, size, or required mutation
        if (Trim(Params.NewType) <> '') or (Params.NewSize > 0) or LHasRequired then
          LNewDict.FieldsDescriptor.UpdateSetupAndOffsets;

        // Apply rename
        if LIsRename then
        begin
          LNewDict.FieldsDescriptor.FieldDescriptor[LFieldIdx].ChangeName(Params.NewName);
          LChanges.Add('renamed=' + Params.NewName);
        end;

        // Check if restructure is needed
        if LOldDict.IsEqual(LNewDict) then
          raise Exception.Create('No changes detected');

        // Create mapper and restructure
        LMapper := TnxTableMapperDescriptor.Create;
        try
          LMapper.MapAllTablesAndFieldsByName(LOldDict, LNewDict);

          // Add rename mapping if needed
          if LIsRename then
            TnxRecordMapperDescriptor(LMapper.RecordMapper).AddMapping(Params.ColumnName, Params.NewName);

          nxCheck(nxmodule.nxDatabase1.RestructureTableEx(Params.TableName, nxmodule.TablePassword,
            LNewDict, LMapper, LTaskInfo));

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
        finally
          LMapper.Free;
        end;
      finally
        LNewDict.Free;
      end;
    finally
      LOldDict.Free;
    end;

    // Build result
    LResultObj := TJSONObject.Create;
    try
      LResultObj.AddPair('success', TJSONBool.Create(True));
      LResultObj.AddPair('tableName', Params.TableName);
      LResultObj.AddPair('columnName', Params.ColumnName);
      LResultObj.AddPair('changes', LChanges.CommaText);
      if LIsRename then
        LResultObj.AddPair('newColumnName', Params.NewName);
      Result := LResultObj.ToJSON;
    finally
      LResultObj.Free;
    end;
  finally
    LChanges.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('modify_column',
    function: IMCPTool
    begin
      Result := TModifyColumnTool.Create;
    end
  );

end.
