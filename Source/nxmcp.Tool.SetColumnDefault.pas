unit nxmcp.Tool.SetColumnDefault;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TSetColumnDefaultParams = class
  private
    FTableName: string;
    FColumnName: string;
    FDefaultType: string;
    FConstantValue: string;
    FApplyAt: string;
    FApplyOnInsert: Boolean;
    FApplyOnModify: Boolean;
    FOverwriteNonNull: Boolean;
  public
    [SchemaDescription('Name of the table containing the column')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the column to configure')]
    property ColumnName: string read FColumnName write FColumnName;

    [SchemaDescription('Default type: none (remove), CurrentDateTime, CurrentUser, or Constant')]
    property DefaultType: string read FDefaultType write FDefaultType;

    [Optional]
    [SchemaDescription('For Constant: literal default value as a string, parsed against the field type. Required when defaultType=Constant.')]
    property ConstantValue: string read FConstantValue write FConstantValue;

    [Optional]
    [SchemaDescription('Where the default is applied: client, server, or both. Default: both')]
    property ApplyAt: string read FApplyAt write FApplyAt;

    [Optional]
    [SchemaDescription('Apply default on insert')]
    property ApplyOnInsert: Boolean read FApplyOnInsert write FApplyOnInsert;

    [Optional]
    [SchemaDescription('Apply default on modify/update')]
    property ApplyOnModify: Boolean read FApplyOnModify write FApplyOnModify;

    [Optional]
    [SchemaDescription('Overwrite existing non-null values with the default')]
    property OverwriteNonNull: Boolean read FOverwriteNonNull write FOverwriteNonNull;
  end;

  TSetColumnDefaultTool = class(TMCPToolBase<TSetColumnDefaultParams>)
  protected
    function ExecuteWithParams(const Params: TSetColumnDefaultParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdTypes,
  nxsdDataDictionary,
  nxsdServerEngine,
  nxsdTableMapperDescriptor,
  nxllException,
  MCPServer.Registration,
  dmnx,
  nxmcp.ColumnSpec;

{ TSetColumnDefaultTool }

constructor TSetColumnDefaultTool.Create;
begin
  inherited;
  FName := 'set_column_default';
  FTitle := 'Set Column Default';
  FDescription := 'Add, replace, or remove the default-value descriptor on an existing column. Supports CurrentDateTime, CurrentUser, and Constant defaults; use defaultType=none to remove.';
end;

function TSetColumnDefaultTool.ExecuteWithParams(const Params: TSetColumnDefaultParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LFieldIdx: Integer;
  LField: TnxFieldDescriptor;
  LMode, LApplyAt: string;
begin
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.ColumnName) = '' then
    raise Exception.Create('Column name cannot be empty');

  LMode := Trim(Params.DefaultType);
  if (not SameText(LMode, 'none')) and
     (not SameText(LMode, 'CurrentDateTime')) and
     (not SameText(LMode, 'CurrentUser')) and
     (not SameText(LMode, 'Constant')) then
    raise Exception.CreateFmt('Unknown defaultType "%s". Use none, CurrentDateTime, CurrentUser, or Constant.', [Params.DefaultType]);

  if SameText(LMode, 'Constant') and (Params.ConstantValue = '') then
    raise Exception.Create('constantValue must be provided when defaultType=Constant');

  LApplyAt := Trim(Params.ApplyAt);
  if LApplyAt = '' then
    LApplyAt := 'both';
  if (not SameText(LApplyAt, 'client')) and
     (not SameText(LApplyAt, 'server')) and
     (not SameText(LApplyAt, 'both')) then
    raise Exception.CreateFmt('Unknown applyAt "%s". Use client, server, or both.', [Params.ApplyAt]);

  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  nxmodule.nxSession1.CloseInactiveTables;

  LOldDict := TnxDataDictionary.Create;
  try
    nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

    LFieldIdx := LOldDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);
    if LFieldIdx < 0 then
      raise Exception.CreateFmt('Column "%s" not found in table "%s"', [Params.ColumnName, Params.TableName]);

    LNewDict := TnxDataDictionary.Create;
    try
      LNewDict.Assign(LOldDict);

      LFieldIdx := LNewDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);
      LField := LNewDict.FieldsDescriptor.FieldDescriptor[LFieldIdx];

      SetFieldDefault(LField, LMode, Params.ConstantValue, LApplyAt,
        Params.ApplyOnInsert, Params.ApplyOnModify, Params.OverwriteNonNull);

      if LOldDict.IsEqual(LNewDict) then
      begin
        LResultObj := TJSONObject.Create;
        try
          LResultObj.AddPair('success', TJSONBool.Create(True));
          LResultObj.AddPair('tableName', Params.TableName);
          LResultObj.AddPair('columnName', Params.ColumnName);
          LResultObj.AddPair('defaultType', LMode);
          LResultObj.AddPair('noChange', TJSONBool.Create(True));
          Result := LResultObj.ToJSON;
          Exit;
        finally
          LResultObj.Free;
        end;
      end;

      LMapper := TnxTableMapperDescriptor.Create;
      try
        LMapper.MapAllTablesAndFieldsByName(LOldDict, LNewDict);

        nxCheck(nxmodule.nxDatabase1.RestructureTableEx(Params.TableName, nxmodule.TablePassword,
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

  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('columnName', Params.ColumnName);
    LResultObj.AddPair('defaultType', LMode);
    if SameText(LMode, 'Constant') then
      LResultObj.AddPair('constantValue', Params.ConstantValue);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('set_column_default',
    function: IMCPTool
    begin
      Result := TSetColumnDefaultTool.Create;
    end
  );

end.
