unit nxmcp.Tool.AddColumn;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  /// <summary>
  /// Parameters for the add_column tool
  /// </summary>
  TAddColumnParams = class
  private
    FTableName: string;
    FColumnName: string;
    FColumnType: string;
    FSize: Integer;
    FRequired: Boolean;
    FDescription: string;
    FDefaultValueType: string;
    FConstantValue: string;
    FApplyAt: string;
    FApplyOnModify: Boolean;
    FOverwriteNonNull: Boolean;
  public
    [SchemaDescription('Name of the table to add the column to')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the new column')]
    property ColumnName: string read FColumnName write FColumnName;

    [SchemaDescription('Column type: Boolean, Char, WideChar, Byte, Word, Word32, Int8, Int16, Integer, Int64, AutoInc, Single, Float, Extended, Currency, Date, Time, DateTime, Blob, Memo, Graphic, ByteArray, ShortString, NullString, WideString, RecRev, Guid, BCD, WideMemo, FmtBCD, RefNr')]
    property ColumnType: string read FColumnType write FColumnType;

    [Optional]
    [SchemaDescription('Size/length for string types (default: 0)')]
    property Size: Integer read FSize write FSize;

    [Optional]
    [SchemaDescription('Make the column required (NOT NULL). Default: false. Note: adding a required column to a table that already has records may fail unless a default is supplied.')]
    property Required: Boolean read FRequired write FRequired;

    [Optional]
    [SchemaDescription('Optional description (comment) for the new column')]
    property Description: string read FDescription write FDescription;

    [Optional]
    [SchemaDescription('Default value type: CurrentDateTime, CurrentUser, or Constant (optional). The default is applied on insert; use set_column_default for finer control.')]
    property DefaultValueType: string read FDefaultValueType write FDefaultValueType;

    [Optional]
    [SchemaDescription('For Constant default: the literal value as a string, parsed against the field type. Required when defaultValueType=Constant.')]
    property ConstantValue: string read FConstantValue write FConstantValue;

    [Optional]
    [SchemaDescription('Where the default is applied: client, server, or both. Default: both')]
    property ApplyAt: string read FApplyAt write FApplyAt;

    [Optional]
    [SchemaDescription('Also apply the default value on modify/update (default: false)')]
    property ApplyOnModify: Boolean read FApplyOnModify write FApplyOnModify;

    [Optional]
    [SchemaDescription('Overwrite existing non-null values with default (default: false)')]
    property OverwriteNonNull: Boolean read FOverwriteNonNull write FOverwriteNonNull;
  end;

  /// <summary>
  /// MCP Tool that adds a column to an existing table
  /// </summary>
  TAddColumnTool = class(TSerializedToolBase<TAddColumnParams>)
  protected
    function ExecuteWithParams(const Params: TAddColumnParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdTypes,
  nxsdDataDictionary,
  nxsdTableMapperDescriptor,
  nxsdServerEngine,
  nxllException,
  MCPServer.Registration,
  dmnx,
  nxmcp.FieldTypes,
  nxmcp.ColumnSpec;

{ TAddColumnTool }

constructor TAddColumnTool.Create;
begin
  inherited;
  FName := 'add_column';
  FTitle := 'Add Column';
  FDescription := 'Add a new column to an existing table. Optionally set required (NOT NULL), a description, and a default value.';
end;

function TAddColumnTool.ExecuteWithParams(const Params: TAddColumnParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LFieldType: TnxFieldType;
  LField: TnxFieldDescriptor;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.ColumnName) = '' then
    raise Exception.Create('Column name cannot be empty');

  if Trim(Params.ColumnType) = '' then
    raise Exception.Create('Column type cannot be empty');

  LFieldType := StringToFieldType(Params.ColumnType);

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Close any open tables to avoid conflicts
  nxmodule.nxSession1.CloseInactiveTables;

  LOldDict := TnxDataDictionary.Create;
  try
    // Get existing dictionary
    nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

    // Check if column already exists
    if LOldDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName) >= 0 then
      raise Exception.CreateFmt('Column "%s" already exists in table "%s"', [Params.ColumnName, Params.TableName]);

    // Create new dictionary with added column
    LNewDict := TnxDataDictionary.Create;
    try
      LNewDict.Assign(LOldDict);

      // Add the new field
      LField := LNewDict.FieldsDescriptor.AddField(Params.ColumnName, '', LFieldType, Params.Size, 0, False);

      // Description
      if Trim(Params.Description) <> '' then
        LField.fdDesc := Params.Description;

      // Required (NOT NULL)
      LField.fdRequired := Params.Required;

      // Default value (applied on insert; modify/overwrite per params)
      if Trim(Params.DefaultValueType) <> '' then
        SetFieldDefault(LField, Params.DefaultValueType, Params.ConstantValue, Params.ApplyAt,
          True, Params.ApplyOnModify, Params.OverwriteNonNull);

      // Reconcile setup/offsets after the required-flag change
      LNewDict.FieldsDescriptor.UpdateSetupAndOffsets;

      // Check if restructure is needed
      if LOldDict.IsEqual(LNewDict) then
        raise Exception.Create('No changes detected');

      // Create mapper and restructure
      LMapper := TnxTableMapperDescriptor.Create;
      try
        LMapper.MapAllTablesAndFieldsByName(LOldDict, LNewDict);

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
    LResultObj.AddPair('columnType', Params.ColumnType);
    LResultObj.AddPair('required', TJSONBool.Create(Params.Required));
    if Trim(Params.DefaultValueType) <> '' then
      LResultObj.AddPair('defaultValueType', Params.DefaultValueType);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('add_column',
    function: IMCPTool
    begin
      Result := TAddColumnTool.Create;
    end
  );

end.
