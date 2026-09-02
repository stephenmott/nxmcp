unit nxmcp.Tool.SetFieldValidator;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TSetFieldValidatorParams = class
  private
    FTableName: string;
    FColumnName: string;
    FValidator: string;
    FMinValue: string;
    FMaxValue: string;
    FMinNull: Boolean;
    FMaxNull: Boolean;
  public
    [SchemaDescription('Name of the table containing the column')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the column on which to set the validator')]
    property ColumnName: string read FColumnName write FColumnName;

    [SchemaDescription('Validator type: none (remove any), minmax, or nochange')]
    property Validator: string read FValidator write FValidator;

    [Optional]
    [SchemaDescription('For minmax: minimum value as a string (parsed against the field type). Ignored unless validator=minmax.')]
    property MinValue: string read FMinValue write FMinValue;

    [Optional]
    [SchemaDescription('For minmax: maximum value as a string (parsed against the field type). Ignored unless validator=minmax.')]
    property MaxValue: string read FMaxValue write FMaxValue;

    [Optional]
    [SchemaDescription('For minmax: when true, leave minimum unbounded (NULL). Default false.')]
    property MinNull: Boolean read FMinNull write FMinNull;

    [Optional]
    [SchemaDescription('For minmax: when true, leave maximum unbounded (NULL). Default false.')]
    property MaxNull: Boolean read FMaxNull write FMaxNull;
  end;

  TSetFieldValidatorTool = class(TMCPToolBase<TSetFieldValidatorParams>)
  protected
    function ExecuteWithParams(const Params: TSetFieldValidatorParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.Variants,
  nxsdTypes,
  nxsdDataDictionary,
  nxsdServerEngine,
  nxsdTableMapperDescriptor,
  nxllException,
  MCPServer.Registration,
  dmnx;

{ TSetFieldValidatorTool }

constructor TSetFieldValidatorTool.Create;
begin
  inherited;
  FName := 'set_field_validator';
  FTitle := 'Set Field Validator';
  FDescription := 'Add, replace, or remove a server-side validator on a column. Supports MinMax (range bounds) and NoChange (immutable after insert). Use validator=none to remove any existing validator.';
end;

procedure RemoveValidatorIfPresent(const AField: TnxFieldDescriptor; const AClassName: string);
var
  LIdx: Integer;
begin
  if not Assigned(AField.fdValidations) then
    Exit;
  LIdx := AField.fdValidations.GetValidationDescriptorFromClassName(AClassName);
  if LIdx >= 0 then
    AField.fdValidations.RemoveValidation(LIdx);
end;

function TSetFieldValidatorTool.ExecuteWithParams(const Params: TSetFieldValidatorParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LFieldIdx, LValidatorIdx: Integer;
  LField: TnxFieldDescriptor;
  LVD: TnxFieldValidationsDescriptor;
  LMinMax: TnxMinMaxValidationDescriptor;
  LMode: string;
begin
  try
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.ColumnName) = '' then
    raise Exception.Create('Column name cannot be empty');

  LMode := LowerCase(Trim(Params.Validator));
  if (LMode <> 'none') and (LMode <> 'minmax') and (LMode <> 'nochange') then
    raise Exception.CreateFmt('Unknown validator "%s". Use none, minmax, or nochange.', [Params.Validator]);

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

      if LMode = 'none' then
      begin
        RemoveValidatorIfPresent(LField, TnxMinMaxValidationDescriptor.ClassName);
        RemoveValidatorIfPresent(LField, TnxNoChangeValidationDescriptor.ClassName);
      end
      else if LMode = 'minmax' then
      begin
        // Remove any existing NoChange validator — only one validator at a time
        RemoveValidatorIfPresent(LField, TnxNoChangeValidationDescriptor.ClassName);

        LVD := LField.EnsureValidations;
        LValidatorIdx := LVD.GetValidationDescriptorFromClassName(TnxMinMaxValidationDescriptor.ClassName);
        if LValidatorIdx < 0 then
        begin
          LVD.AddValidation('MCP_Min_Max', TnxMinMaxValidationDescriptor);
          LValidatorIdx := LVD.GetValidationDescriptorFromClassName(TnxMinMaxValidationDescriptor.ClassName);
        end;
        LMinMax := LVD.ValidationDescriptor[LValidatorIdx] as TnxMinMaxValidationDescriptor;

        if Params.MinNull or (Trim(Params.MinValue) = '') then
          LMinMax.MinAsVariant := Null
        else
          LMinMax.MinAsVariant := Params.MinValue;

        if Params.MaxNull or (Trim(Params.MaxValue) = '') then
          LMinMax.MaxAsVariant := Null
        else
          LMinMax.MaxAsVariant := Params.MaxValue;
      end
      else // nochange
      begin
        RemoveValidatorIfPresent(LField, TnxMinMaxValidationDescriptor.ClassName);

        LVD := LField.EnsureValidations;
        LValidatorIdx := LVD.GetValidationDescriptorFromClassName(TnxNoChangeValidationDescriptor.ClassName);
        if LValidatorIdx < 0 then
          LVD.AddValidation('MCP_No_Change', TnxNoChangeValidationDescriptor);
      end;

      if LOldDict.IsEqual(LNewDict) then
      begin
        LResultObj := TJSONObject.Create;
        try
          LResultObj.AddPair('success', TJSONBool.Create(True));
          LResultObj.AddPair('tableName', Params.TableName);
          LResultObj.AddPair('columnName', Params.ColumnName);
          LResultObj.AddPair('validator', LMode);
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
    LResultObj.AddPair('validator', LMode);
    if LMode = 'minmax' then
    begin
      if Params.MinNull or (Trim(Params.MinValue) = '') then
        LResultObj.AddPair('minValue', TJSONNull.Create)
      else
        LResultObj.AddPair('minValue', Params.MinValue);
      if Params.MaxNull or (Trim(Params.MaxValue) = '') then
        LResultObj.AddPair('maxValue', TJSONNull.Create)
      else
        LResultObj.AddPair('maxValue', Params.MaxValue);
    end;
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
  except
    on E: Exception do
    begin
      if Assigned(nxmodule) then
        nxmodule.RecoverSessionAfterError(E);
      raise;
    end;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('set_field_validator',
    function: IMCPTool
    begin
      Result := TSetFieldValidatorTool.Create;
    end
  );

end.
