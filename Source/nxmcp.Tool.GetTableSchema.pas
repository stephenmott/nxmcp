unit nxmcp.Tool.GetTableSchema;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TGetTableSchemaParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to get schema for')]
    property TableName: string read FTableName write FTableName;
  end;

  TGetTableSchemaTool = class(TMCPToolBase<TGetTableSchemaParams>)
  protected
    function ExecuteWithParams(const Params: TGetTableSchemaParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.Variants,
  nxsdTypes,
  nxsdDataDictionary,
  nxsdDataDictionaryAudit,
  nxsdDataDictionaryDataPolicies,
  nxsdDataDictionaryRefInt,
  nxsdDataDictionaryStrings,
  nxllException,
  MCPServer.Registration,
  nxmcp.SqlUtils,
  dmnx,
  nxmcp.FieldTypes;

{ TGetTableSchemaTool }

constructor TGetTableSchemaTool.Create;
begin
  inherited;
  FName := 'get_table_schema';
  FTitle := 'Get Table Schema';
  FDescription := 'Get detailed schema information for a table from its data dictionary: columns (with descriptions, defaults, validators), indexes (with descriptions), table description, data policies, audit settings, and referential integrity references.';
end;

function VariantToJSONValue(const V: Variant): TJSONValue;
begin
  if VarIsNull(V) or VarIsEmpty(V) then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(VarToStr(V));
end;

function BuildDefaultJSON(const ADefault: TnxBaseDefaultValueDescriptor): TJSONObject;
var
  LObj: TJSONObject;
  LApplyAt: string;
begin
  LObj := TJSONObject.Create;
  LObj.AddPair('type', ADefault.ClassName);
  if ADefault is TnxConstDefaultValueDescriptor then
    LObj.AddPair('value', VariantToJSONValue(TnxConstDefaultValueDescriptor(ADefault).AsVariant));

  if ADefault.ApplyAt = [aaClient] then
    LApplyAt := 'client'
  else if ADefault.ApplyAt = [aaServer] then
    LApplyAt := 'server'
  else if ADefault.ApplyAt = [aaClient, aaServer] then
    LApplyAt := 'both'
  else
    LApplyAt := 'none';

  LObj.AddPair('applyAt', LApplyAt);
  LObj.AddPair('applyOnInsert', TJSONBool.Create(ADefault.ApplyOnInsert));
  LObj.AddPair('applyOnModify', TJSONBool.Create(ADefault.ApplyOnModify));
  LObj.AddPair('overwriteNonNull', TJSONBool.Create(ADefault.OverwriteNonNull));
  Result := LObj;
end;

function BuildValidatorsJSON(const AField: TnxFieldDescriptor): TJSONArray;
var
  LArr: TJSONArray;
  LObj: TJSONObject;
  LMinMax: TnxMinMaxValidationDescriptor;
  I: Integer;
begin
  LArr := TJSONArray.Create;
  if not Assigned(AField.fdValidations) then
    Exit(LArr);

  for I := 0 to AField.fdValidations.ValidationCount - 1 do
  begin
    LObj := TJSONObject.Create;
    LObj.AddPair('type', AField.fdValidations.ValidationDescriptor[I].ClassName);

    if AField.fdValidations.ValidationDescriptor[I] is TnxMinMaxValidationDescriptor then
    begin
      LMinMax := TnxMinMaxValidationDescriptor(AField.fdValidations.ValidationDescriptor[I]);
      LObj.AddPair('min', VariantToJSONValue(LMinMax.MinAsVariant));
      LObj.AddPair('max', VariantToJSONValue(LMinMax.MaxAsVariant));
    end;

    LArr.AddElement(LObj);
  end;
  Result := LArr;
end;

function BuildDataPoliciesJSON(const ADict: TnxDataDictionary): TJSONObject;
var
  LDP: TnxDataPoliciesDescriptor;
begin
  LDP := GetDataPoliciesDescriptor(ADict);
  if not Assigned(LDP) then
    Exit(nil);

  Result := TJSONObject.Create;
  Result.AddPair('denyInsert', TJSONBool.Create(TnxRecordOperation.roInsert in LDP.DenyRecordOperations));
  Result.AddPair('denyModify', TJSONBool.Create(TnxRecordOperation.roModify in LDP.DenyRecordOperations));
  Result.AddPair('denyDelete', TJSONBool.Create(TnxRecordOperation.roDelete in LDP.DenyRecordOperations));
  Result.AddPair('minRecordCount', TJSONNumber.Create(LDP.MinRecordCount));
  Result.AddPair('maxRecordCount', TJSONNumber.Create(LDP.MaxRecordCount));
end;

function BuildAuditJSON(const ADict: TnxDataDictionary): TJSONObject;
var
  LIdx: Integer;
  LAudit: TnxAuditDescriptor;
begin
  LIdx := ADict.CustomDescsDescriptor.GetCustomDescriptorFromName(csAuditDescriptorName);
  if LIdx < 0 then
    Exit(nil);

  LAudit := ADict.CustomDescsDescriptor.CustomDescriptor[LIdx] as TnxAuditDescriptor;
  Result := TJSONObject.Create;
  Result.AddPair('useAudit', TJSONBool.Create(LAudit.UseAudit));
  Result.AddPair('includeBlobFields', TJSONBool.Create(LAudit.IncludeBlobFields));
end;

type
  TnxCrackIndexDescriptor = class(TnxIndexDescriptor);

procedure DescribeTargetCursor(ACursor: TObject; out ATargetType, ATableName: string);
begin
  ATableName := '';
  if ACursor is TnxTableTargetCursorDescriptor then
  begin
    ATargetType := 'Table';
    ATableName := TnxTableTargetCursorDescriptor(ACursor).TableName;
  end
  else if ACursor is TnxRelativeTargetCursorDescriptor then
  begin
    ATargetType := 'Relative';
    ATableName := TnxRelativeTargetCursorDescriptor(ACursor).TableName;
  end
  else if ACursor is TnxCloneTargetCursorDescriptor then
    ATargetType := 'Clone'
  else
    ATargetType := ACursor.ClassName;
end;

function BuildReferencesJSON(const ADict: TnxDataDictionary): TJSONArray;
var
  LRI: TnxRefIntegrityDescriptor;
  LRef: TnxReferenceDescriptor;
  LRefObj: TJSONObject;
  LSourcesArr: TJSONArray;
  LSourceObj: TJSONObject;
  LActionsArr: TJSONArray;
  LFieldSource: TnxFieldSourceDescriptor;
  LTargetType, LTableName, LFieldName: string;
  I, J: Integer;
begin
  Result := TJSONArray.Create;

  LRI := GetRefIntegrityDescriptor(ADict);
  if not Assigned(LRI) then
    Exit;

  for I := 0 to LRI.ridReferenceCount - 1 do
  begin
    LRef := LRI.ridReferences[I];
    LRefObj := TJSONObject.Create;

    if Assigned(LRef.TargetCursor) then
    begin
      DescribeTargetCursor(LRef.TargetCursor, LTargetType, LTableName);
      LRefObj.AddPair('targetType', LTargetType);
      LRefObj.AddPair('targetTable', LTableName);
    end;

    LRefObj.AddPair('targetIndex', LRef.TargetIndex);

    LSourcesArr := TJSONArray.Create;
    for J := 0 to LRef.rdSourceCount - 1 do
    begin
      LFieldSource := TnxFieldSourceDescriptor(LRef.rdSources[J]);
      LSourceObj := TJSONObject.Create;
      if (LFieldSource.FieldNumber >= 0) and
         (LFieldSource.FieldNumber < ADict.FieldsDescriptor.FieldCount) then
        LFieldName := ADict.FieldsDescriptor.FieldDescriptor[LFieldSource.FieldNumber].Name
      else
        LFieldName := '';
      LSourceObj.AddPair('fieldName', LFieldName);
      LSourceObj.AddPair('skipOnNull', TJSONBool.Create(LFieldSource.SkipOnNull));
      LSourcesArr.AddElement(LSourceObj);
    end;
    LRefObj.AddPair('sourceFields', LSourcesArr);

    LActionsArr := TJSONArray.Create;
    for J := 0 to LRef.rdActionCount - 1 do
      LActionsArr.Add(LRef.rdActions[J].ClassName);
    LRefObj.AddPair('actions', LActionsArr);

    Result.AddElement(LRefObj);
  end;
end;

function TGetTableSchemaTool.ExecuteWithParams(const Params: TGetTableSchemaParams): string;
var
  LResultObj: TJSONObject;
  LColumnsArray, LIndexesArray, LFieldsArr, LValidators, LRefs: TJSONArray;
  LColumnObj, LIndexObj, LDefaultObj, LDP, LAudit: TJSONObject;
  LDict: TnxDataDictionary;
  LField: TnxFieldDescriptor;
  LIndex: TnxIndexDescriptor;
  LKey: TnxCompKeyDescriptor;
  LRecordCount: Integer;
  I, J: Integer;
begin
  // The name reaches a concatenated SELECT COUNT(*) further down, so validate it
  // against NexusDB's own identifier rules before it gets there.
  CheckTableName(Params.TableName);

  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('tableName', Params.TableName);

    LDict := TnxDataDictionary.Create;
    try
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(
            Params.TableName, nxmodule.TablePassword, LDict));
        end);

      // Table-level description
      if LDict.FilesDescriptor.FileCount > 0 then
        LResultObj.AddPair('description', LDict.FilesDescriptor.FileDescriptor[0].Desc);

      // Columns
      LColumnsArray := TJSONArray.Create;
      LResultObj.AddPair('columns', LColumnsArray);

      for I := 0 to LDict.FieldsDescriptor.FieldCount - 1 do
      begin
        LField := LDict.FieldsDescriptor.FieldDescriptor[I];
        LColumnObj := TJSONObject.Create;
        LColumnObj.AddPair('name', LField.Name);
        LColumnObj.AddPair('type', FieldTypeToString(LField.fdType));
        LColumnObj.AddPair('units', TJSONNumber.Create(LField.fdUnits));
        LColumnObj.AddPair('decimals', TJSONNumber.Create(LField.fdDecPl));
        LColumnObj.AddPair('required', TJSONBool.Create(LField.fdRequired));
        LColumnObj.AddPair('description', LField.fdDesc);

        if Assigned(LField.fdDefaultValue) then
        begin
          LDefaultObj := BuildDefaultJSON(LField.fdDefaultValue);
          LColumnObj.AddPair('default', LDefaultObj);
        end;

        LValidators := BuildValidatorsJSON(LField);
        if LValidators.Count > 0 then
          LColumnObj.AddPair('validators', LValidators)
        else
          LValidators.Free;

        LColumnsArray.AddElement(LColumnObj);
      end;
      LResultObj.AddPair('columnCount', TJSONNumber.Create(LColumnsArray.Count));

      // Indexes
      LIndexesArray := TJSONArray.Create;
      LResultObj.AddPair('indexes', LIndexesArray);

      if Assigned(LDict.IndicesDescriptor) then
      begin
        for I := 0 to LDict.IndicesDescriptor.IndexCount - 1 do
        begin
          LIndex := LDict.IndicesDescriptor.IndexDescriptor[I];
          LIndexObj := TJSONObject.Create;
          LIndexObj.AddPair('name', LIndex.Name);
          LIndexObj.AddPair('unique', TJSONBool.Create(LIndex.Dups = idNone));
          LIndexObj.AddPair('isDefault', TJSONBool.Create(LDict.IndicesDescriptor.DefaultIndex = LIndex.Number));
          LIndexObj.AddPair('description', TnxCrackIndexDescriptor(LIndex).idDesc);

          LFieldsArr := TJSONArray.Create;
          if LIndex.KeyDescriptor is TnxCompKeyDescriptor then
          begin
            LKey := TnxCompKeyDescriptor(LIndex.KeyDescriptor);
            for J := 0 to LKey.KeyFieldCount - 1 do
              if LKey.KeyFields[J].FieldNumber >= 0 then
                LFieldsArr.Add(LKey.KeyFields[J].Field.Name);
          end;
          LIndexObj.AddPair('fields', LFieldsArr);

          LIndexesArray.AddElement(LIndexObj);
        end;
      end;
      LResultObj.AddPair('indexCount', TJSONNumber.Create(LIndexesArray.Count));

      // Data policies
      LDP := BuildDataPoliciesJSON(LDict);
      if Assigned(LDP) then
        LResultObj.AddPair('dataPolicies', LDP);

      // Audit
      LAudit := BuildAuditJSON(LDict);
      if Assigned(LAudit) then
        LResultObj.AddPair('audit', LAudit);

      // Referential integrity (read-only)
      LRefs := BuildReferencesJSON(LDict);
      if LRefs.Count > 0 then
        LResultObj.AddPair('references', LRefs)
      else
        LRefs.Free;
    finally
      LDict.Free;
    end;

    // Record count (from SQL)
    try
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          nxmodule.nxQuery1.Close;
          nxmodule.nxQuery1.SQL.Text := 'SELECT COUNT(*) FROM "' + Params.TableName + '"';
          nxmodule.nxQuery1.Open;
          try
            LRecordCount := nxmodule.nxQuery1.Fields[0].AsInteger;
          finally
            nxmodule.nxQuery1.Close;
          end;
        end);
    except
      on E: Exception do
      begin
        // ExecuteWithReconnect retires the session before re-raising a timeout,
        // re-entry, or communication-loss failure. Do not hide that poisoned
        // session outcome behind the optional -1 record-count fallback.
        if Tnxmodule.IsTimeoutError(E) or Tnxmodule.IsReenteredError(E) or
          Tnxmodule.IsConnectionLostError(E) then
          raise;
        LRecordCount := -1;
      end;
    end;
    LResultObj.AddPair('recordCount', TJSONNumber.Create(LRecordCount));

    Result := LResultObj.ToJSON;
  except
    LResultObj.Free;
    raise;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('get_table_schema',
    function: IMCPTool
    begin
      Result := TGetTableSchemaTool.Create;
    end
  );

end.
