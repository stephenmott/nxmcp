unit nxmcp.ColumnSpec;

{
  Shared helpers for applying column-level metadata (default values,
  descriptions, required flag) to a TnxFieldDescriptor. Used by create_table,
  add_column, modify_column and set_column_default so the logic lives in one
  place.
}

interface

uses
  System.SysUtils,
  System.JSON,
  nxsdTypes,
  nxsdDataDictionary;

/// <summary>
/// Apply (or remove) a default-value descriptor on a field.
/// ADefaultType is one of: none, CurrentDateTime, CurrentUser, Constant.
/// AApplyAt is one of: client, server, both (empty = both).
/// Raises on invalid input. 'none' simply removes any existing default.
/// </summary>
procedure SetFieldDefault(AField: TnxFieldDescriptor;
  const ADefaultType, AConstantValue, AApplyAt: string;
  AApplyOnInsert, AApplyOnModify, AOverwriteNonNull: Boolean);

/// <summary>
/// Apply a default-value descriptor from a JSON object of the shape
/// { "type": "...", "constantValue": "...", "applyAt": "...",
///   "applyOnInsert": true, "applyOnModify": false, "overwriteNonNull": false }.
/// Missing keys fall back to sensible defaults (applyAt=both,
/// applyOnInsert=true, applyOnModify=false, overwriteNonNull=false).
/// </summary>
procedure SetFieldDefaultFromJSON(AField: TnxFieldDescriptor; ADefObj: TJSONObject);

/// <summary>
/// Apply the optional metadata keys (description, required, default) from a
/// create_table/add_column column-definition object to a freshly added field.
/// The caller is responsible for calling UpdateSetupAndOffsets afterwards when
/// 'required' may have changed.
/// </summary>
procedure ApplyColumnMetadataFromJSON(AField: TnxFieldDescriptor; AColObj: TJSONObject);

implementation

function JSONBoolDef(AObj: TJSONObject; const AKey: string; ADefault: Boolean): Boolean;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AObj) then
    Exit;
  LValue := AObj.GetValue(AKey);
  if not Assigned(LValue) then
    Exit;
  if LValue is TJSONBool then
    Result := TJSONBool(LValue).AsBoolean
  else
    Result := SameText(LValue.Value, 'true');
end;

function JSONStrDef(AObj: TJSONObject; const AKey: string; const ADefault: string): string;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AObj) then
    Exit;
  LValue := AObj.GetValue(AKey);
  if Assigned(LValue) then
    Result := LValue.Value;
end;

procedure SetFieldDefault(AField: TnxFieldDescriptor;
  const ADefaultType, AConstantValue, AApplyAt: string;
  AApplyOnInsert, AApplyOnModify, AOverwriteNonNull: Boolean);
var
  LMode, LApplyAt: string;
begin
  LMode := Trim(ADefaultType);
  if (not SameText(LMode, 'none')) and
     (not SameText(LMode, 'CurrentDateTime')) and
     (not SameText(LMode, 'CurrentUser')) and
     (not SameText(LMode, 'Constant')) then
    raise Exception.CreateFmt(
      'Unknown default type "%s". Use none, CurrentDateTime, CurrentUser, or Constant.',
      [ADefaultType]);

  if SameText(LMode, 'Constant') and (AConstantValue = '') then
    raise Exception.Create('constantValue must be provided when the default type is Constant');

  LApplyAt := Trim(AApplyAt);
  if LApplyAt = '' then
    LApplyAt := 'both';
  if (not SameText(LApplyAt, 'client')) and
     (not SameText(LApplyAt, 'server')) and
     (not SameText(LApplyAt, 'both')) then
    raise Exception.CreateFmt('Unknown applyAt "%s". Use client, server, or both.', [AApplyAt]);

  // Always remove any existing default first to get a clean slate
  if Assigned(AField.fdDefaultValue) then
    AField.RemoveDefaultValue;

  if SameText(LMode, 'none') then
    Exit;

  if SameText(LMode, 'CurrentDateTime') then
    AField.AddDefaultValue(TnxCurrentDateTimeDefaultValueDescriptor)
  else if SameText(LMode, 'CurrentUser') then
    AField.AddDefaultValue(TnxCurrentUserDefaultValueDescriptor)
  else // Constant
  begin
    AField.AddDefaultValue(TnxConstDefaultValueDescriptor);
    TnxConstDefaultValueDescriptor(AField.fdDefaultValue).AsVariant := AConstantValue;
  end;

  if SameText(LApplyAt, 'client') then
    AField.fdDefaultValue.ApplyAt := [aaClient]
  else if SameText(LApplyAt, 'server') then
    AField.fdDefaultValue.ApplyAt := [aaServer]
  else
    AField.fdDefaultValue.ApplyAt := [aaClient, aaServer];

  AField.fdDefaultValue.ApplyOnInsert := AApplyOnInsert;
  AField.fdDefaultValue.ApplyOnModify := AApplyOnModify;
  AField.fdDefaultValue.OverwriteNonNull := AOverwriteNonNull;
end;

procedure SetFieldDefaultFromJSON(AField: TnxFieldDescriptor; ADefObj: TJSONObject);
var
  LType: string;
begin
  if not Assigned(ADefObj) then
    Exit;

  LType := JSONStrDef(ADefObj, 'type', '');
  if Trim(LType) = '' then
    raise Exception.Create('A column "default" object must include a "type" property');

  SetFieldDefault(AField,
    LType,
    JSONStrDef(ADefObj, 'constantValue', ''),
    JSONStrDef(ADefObj, 'applyAt', 'both'),
    JSONBoolDef(ADefObj, 'applyOnInsert', True),
    JSONBoolDef(ADefObj, 'applyOnModify', False),
    JSONBoolDef(ADefObj, 'overwriteNonNull', False));
end;

procedure ApplyColumnMetadataFromJSON(AField: TnxFieldDescriptor; AColObj: TJSONObject);
var
  LDescValue: TJSONValue;
  LDefaultValue: TJSONValue;
begin
  if not Assigned(AColObj) then
    Exit;

  // Description
  LDescValue := AColObj.GetValue('description');
  if Assigned(LDescValue) then
    AField.fdDesc := LDescValue.Value;

  // Required / NOT NULL (EnterpriseManager sets fdRequired directly during
  // restructure editing; the caller must call UpdateSetupAndOffsets after).
  AField.fdRequired := JSONBoolDef(AColObj, 'required', AField.fdRequired);

  // Default value (object form)
  LDefaultValue := AColObj.GetValue('default');
  if Assigned(LDefaultValue) then
  begin
    if not (LDefaultValue is TJSONObject) then
      raise Exception.CreateFmt(
        'Column "%s": "default" must be an object, e.g. {"type":"CurrentDateTime"}',
        [AField.Name]);
    SetFieldDefaultFromJSON(AField, TJSONObject(LDefaultValue));
  end;
end;

end.
