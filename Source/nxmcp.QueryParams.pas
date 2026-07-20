unit nxmcp.QueryParams;

/// <summary>
/// Binds JSON-supplied parameter values to the :name placeholders of a
/// TnxQuery (used by execute_query / execute_sql).
///
/// Wire format: a JSON array of {"name": ..., "value": ..., "type": ...}
/// objects. "type" is optional; when omitted it is inferred from the JSON
/// value (integral number -> integer, fractional number -> float, true/false
/// -> boolean, string -> string). Explicit types cover values JSON cannot
/// express natively: date, time, datetime, guid, currency, memo and blob
/// (base64). "value": null (or an omitted "value") binds a typed NULL.
///
/// Values are bound as native typed TParams, not spliced into the SQL text,
/// so quoting/escaping and the typed-literal rules for GUID/DATE/TIME/
/// TIMESTAMP columns (see nxmcp.ValueFormat) do not apply. Date/time strings
/// accept the same lenient input as insert_record ('T' or space separator,
/// trailing 'Z'/offset stripped) and are converted to TDateTime client-side,
/// keeping the binding independent of client/server locale settings.
///
/// NexusDB's quParseSql creates one TParam per placeholder OCCURRENCE, so a
/// name repeated in the SQL yields several same-named entries; every match is
/// bound, which is why binding iterates the collection instead of using
/// ParamByName (which only touches the first).
/// </summary>

interface

uses
  nxdb;

/// <summary>
/// Parses AParamsJson and binds each entry to the matching :name parameter(s)
/// of AQuery (case-insensitive, all occurrences). Must be called after
/// AQuery.SQL.Text is set (that is what parses the placeholders). Raises a
/// descriptive exception on malformed JSON, unknown parameter names, invalid
/// values, or placeholders left without a value. An empty/blank AParamsJson
/// is allowed and only performs the missing-value check.
/// </summary>
procedure ApplyJsonParamsToQuery(AQuery: TnxQuery; const AParamsJson: string);

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.NetEncoding,
  System.Generics.Collections,
  Data.DB,
  nxmcp.ValueFormat;

const
  CValidTypes = 'string, memo, integer, float, currency, boolean, date, time, datetime, timestamp, guid, blob';

// Maps a params-array "type" keyword onto the TFieldType used for binding.
// '' means "not specified" and is returned as ftUnknown for the caller to
// infer from the JSON value.
function ParamTypeFromString(const ATypeStr: string): TFieldType;
var
  LType: string;
begin
  LType := LowerCase(Trim(ATypeStr));
  if LType = '' then
    Result := ftUnknown
  else if (LType = 'string') or (LType = 'widestring') then
    Result := ftWideString
  else if (LType = 'memo') or (LType = 'widememo') or (LType = 'text') then
    Result := ftWideMemo
  else if (LType = 'integer') or (LType = 'int') or (LType = 'int64') or
          (LType = 'largeint') or (LType = 'byte') or (LType = 'word') or
          (LType = 'smallint') or (LType = 'shortint') then
    Result := ftLargeint
  else if (LType = 'float') or (LType = 'double') or (LType = 'single') or
          (LType = 'extended') then
    Result := ftFloat
  else if (LType = 'currency') or (LType = 'money') then
    Result := ftCurrency
  else if (LType = 'boolean') or (LType = 'bool') then
    Result := ftBoolean
  else if LType = 'date' then
    Result := ftDate
  else if LType = 'time' then
    Result := ftTime
  else if (LType = 'datetime') or (LType = 'timestamp') then
    Result := ftDateTime
  else if (LType = 'guid') or (LType = 'uuid') then
    Result := ftGuid
  else if (LType = 'blob') or (LType = 'bytes') or (LType = 'binary') then
    Result := ftBlob
  else
    raise Exception.CreateFmt('unknown type "%s" (valid types: %s)',
      [ATypeStr, CValidTypes]);
end;

// Returns the text of a scalar JSON value; rejects arrays/objects.
function ScalarText(AValue: TJSONValue): string;
begin
  if (AValue is TJSONArray) or (AValue is TJSONObject) then
    raise Exception.Create(
      'value must be a scalar (string, number, boolean or null), not an array or object');
  Result := AValue.Value;
end;

function ParseInt64Value(AValue: TJSONValue): Int64;
var
  LText: string;
begin
  LText := Trim(ScalarText(AValue));
  if not TryStrToInt64(LText, Result) then
    raise Exception.CreateFmt(
      '"%s" is not a valid integer (use type "float" for fractional numbers)', [LText]);
end;

function ParseFloatValue(AValue: TJSONValue): Double;
var
  LText: string;
begin
  if AValue is TJSONNumber then
    Exit(TJSONNumber(AValue).AsDouble);
  LText := Trim(ScalarText(AValue));
  if not TryStrToFloat(LText, Result, TFormatSettings.Invariant) then
    raise Exception.CreateFmt('"%s" is not a valid number', [LText]);
end;

function ParseCurrencyValue(AValue: TJSONValue): Currency;
var
  LText: string;
begin
  if AValue is TJSONNumber then
    Exit(TJSONNumber(AValue).AsDouble);
  LText := Trim(ScalarText(AValue));
  if not TryStrToCurr(LText, Result, TFormatSettings.Invariant) then
    raise Exception.CreateFmt('"%s" is not a valid currency amount', [LText]);
end;

function ParseBooleanValue(AValue: TJSONValue): Boolean;
var
  LText: string;
begin
  if AValue is TJSONBool then
    Exit(TJSONBool(AValue).AsBoolean);
  LText := LowerCase(Trim(ScalarText(AValue)));
  if (LText = 'true') or (LText = '1') then
    Result := True
  else if (LText = 'false') or (LText = '0') then
    Result := False
  else
    raise Exception.CreateFmt('"%s" is not a valid boolean (use true or false)', [LText]);
end;

// 'YYYY-MM-DD' (canonical output of NormalizeDateLiteral) -> TDateTime.
function CanonicalDateToDateTime(const S: string): TDateTime;
begin
  Result := EncodeDate(StrToInt(Copy(S, 1, 4)), StrToInt(Copy(S, 6, 2)),
    StrToInt(Copy(S, 9, 2)));
end;

// 'HH:MM:SS[.fff]' (canonical output of NormalizeTimeLiteral) -> TDateTime.
function CanonicalTimeToDateTime(const S: string): TDateTime;
var
  LMs: Integer;
begin
  if Length(S) > 8 then
    LMs := StrToInt(Copy(S, 10, 3))
  else
    LMs := 0;
  Result := EncodeTime(StrToInt(Copy(S, 1, 2)), StrToInt(Copy(S, 4, 2)),
    StrToInt(Copy(S, 7, 2)), LMs);
end;

// 'YYYY-MM-DD HH:MM:SS[.fff]' (canonical output of NormalizeTimestampLiteral)
// -> TDateTime. TDateTime is sign-magnitude: for pre-1899 dates the time of
// day must be subtracted, not added.
function CanonicalTimestampToDateTime(const S: string): TDateTime;
var
  LDate, LTime: TDateTime;
begin
  LDate := CanonicalDateToDateTime(Copy(S, 1, 10));
  LTime := CanonicalTimeToDateTime(Copy(S, 12, MaxInt));
  if LDate < 0 then
    Result := LDate - LTime
  else
    Result := LDate + LTime;
end;

// Picks a binding type for an entry that did not specify "type".
function InferFieldType(AValue: TJSONValue): TFieldType;
var
  LDummy: Int64;
begin
  if AValue is TJSONNumber then
  begin
    // TJSONNumber.Value is the raw JSON literal, so integer detection is
    // exact (no double round-trip).
    if TryStrToInt64(AValue.Value, LDummy) then
      Result := ftLargeint
    else
      Result := ftFloat;
  end
  else if AValue is TJSONBool then
    Result := ftBoolean
  else if AValue is TJSONString then
    Result := ftWideString
  else
    raise Exception.Create(
      'value must be a scalar (string, number, boolean or null), not an array or object');
end;

// Binds one value to one TParam. TParam setter order matters: DataType must
// be assigned before Value, because SetAsVariant only infers a DataType when
// it is still ftUnknown (and would otherwise override the explicit choice).
// The AsXxx property setters already follow that order internally.
procedure BindParamValue(AParam: TParam; AFieldType: TFieldType; AValue: TJSONValue);
var
  LBytes: TBytes;
begin
  // NULL (explicit null or omitted "value"): bind a typed NULL. The DataType
  // must still be a concrete type - nxParamToSqlParamDesc cannot describe an
  // ftUnknown param to the server.
  if (AValue = nil) or (AValue is TJSONNull) then
  begin
    if AFieldType = ftUnknown then
      AFieldType := ftWideString;
    AParam.DataType := AFieldType;
    AParam.Clear;
    Exit;
  end;

  if AFieldType = ftUnknown then
    AFieldType := InferFieldType(AValue);

  case AFieldType of
    ftWideString:
      AParam.AsWideString := ScalarText(AValue);
    ftWideMemo:
      begin
        AParam.DataType := ftWideMemo;
        AParam.Value := ScalarText(AValue);
      end;
    ftLargeint:
      AParam.AsLargeInt := ParseInt64Value(AValue);
    ftFloat:
      AParam.AsFloat := ParseFloatValue(AValue);
    ftCurrency:
      AParam.AsCurrency := ParseCurrencyValue(AValue);
    ftBoolean:
      AParam.AsBoolean := ParseBooleanValue(AValue);
    ftDate:
      AParam.AsDate := CanonicalDateToDateTime(
        NormalizeDateLiteral(ScalarText(AValue)));
    ftTime:
      AParam.AsTime := CanonicalTimeToDateTime(
        NormalizeTimeLiteral(ScalarText(AValue)));
    ftDateTime:
      AParam.AsDateTime := CanonicalTimestampToDateTime(
        NormalizeTimestampLiteral(ScalarText(AValue)));
    ftGuid:
      begin
        // NexusDB converts GUID params with CLSIDFromString, which requires
        // the braced form - NormalizeGuidLiteral produces exactly that.
        AParam.DataType := ftGuid;
        AParam.Value := NormalizeGuidLiteral(ScalarText(AValue));
      end;
    ftBlob:
      begin
        if not (AValue is TJSONString) then
          raise Exception.Create('blob value must be a base64-encoded string');
        try
          LBytes := TNetEncoding.Base64.DecodeStringToBytes(TJSONString(AValue).Value);
        except
          on E: Exception do
            raise Exception.Create('invalid base64 data: ' + E.Message);
        end;
        AParam.AsBlob := TBlobData(LBytes);
      end;
  end;
end;

// Case-insensitive key lookup on a params-array entry ({"Name": ...} works).
function GetEntryValue(AEntry: TJSONObject; const AKey: string): TJSONValue;
var
  LPair: TJSONPair;
begin
  Result := nil;
  for LPair in AEntry do
    if SameText(LPair.JsonString.Value, AKey) then
      Exit(LPair.JsonValue);
end;

// Comma-separated list of the distinct :names parsed from the SQL.
function DescribeSqlParams(AQuery: TnxQuery): string;
var
  LNames: TStringList;
  I: Integer;
begin
  LNames := TStringList.Create;
  try
    LNames.Sorted := True;
    LNames.Duplicates := dupIgnore;
    LNames.CaseSensitive := False;
    for I := 0 to AQuery.Params.Count - 1 do
      LNames.Add(':' + AQuery.Params[I].Name);
    Result := string.Join(', ', LNames.ToStringArray);
  finally
    LNames.Free;
  end;
end;

procedure ApplyJsonParamsToQuery(AQuery: TnxQuery; const AParamsJson: string);
var
  LRoot: TJSONValue;
  LArray: TJSONArray;
  LEntry: TJSONObject;
  LPair: TJSONPair;
  LKey: string;
  LName: string;
  LFieldType: TFieldType;
  LValue: TJSONValue;
  LMatched: Boolean;
  LMissingNames: TStringList;
  LMissing: string;
  I, J: Integer;
begin
  if Trim(AParamsJson) <> '' then
  begin
    LRoot := TJSONObject.ParseJSONValue(AParamsJson);
    if not (LRoot is TJSONArray) then
    begin
      LRoot.Free;
      raise Exception.Create(
        'params must be a JSON array like [{"name":"id","value":42}]');
    end;

    LArray := TJSONArray(LRoot);
    try
      for I := 0 to LArray.Count - 1 do
      begin
        if not (LArray.Items[I] is TJSONObject) then
          raise Exception.CreateFmt(
            'params[%d] must be an object with "name", "value" and optional "type"', [I]);
        LEntry := TJSONObject(LArray.Items[I]);

        // Reject typos like "vaule" - a misspelled "value" key would
        // otherwise silently bind NULL.
        for LPair in LEntry do
        begin
          LKey := LowerCase(LPair.JsonString.Value);
          if (LKey <> 'name') and (LKey <> 'value') and (LKey <> 'type') then
            raise Exception.CreateFmt(
              'params[%d] has unknown key "%s" (allowed keys: name, value, type)',
              [I, LPair.JsonString.Value]);
        end;

        LValue := GetEntryValue(LEntry, 'name');
        if not (LValue is TJSONString) or (Trim(LValue.Value) = '') then
          raise Exception.CreateFmt('params[%d] is missing a non-empty "name"', [I]);
        LName := Trim(LValue.Value);

        LValue := GetEntryValue(LEntry, 'type');
        if Assigned(LValue) and not (LValue is TJSONNull) then
        try
          LFieldType := ParamTypeFromString(ScalarText(LValue));
        except
          on E: Exception do
            raise Exception.CreateFmt('Parameter ":%s": %s', [LName, E.Message]);
        end
        else
          LFieldType := ftUnknown;

        LValue := GetEntryValue(LEntry, 'value');

        // Bind every occurrence: NexusDB creates one TParam per placeholder,
        // so a :name used twice in the SQL has two same-named entries.
        LMatched := False;
        for J := 0 to AQuery.Params.Count - 1 do
          if SameText(AQuery.Params[J].Name, LName) then
          begin
            try
              BindParamValue(AQuery.Params[J], LFieldType, LValue);
            except
              on E: Exception do
                raise Exception.CreateFmt('Parameter ":%s": %s', [LName, E.Message]);
            end;
            LMatched := True;
          end;

        if not LMatched then
        begin
          if AQuery.Params.Count = 0 then
            raise Exception.CreateFmt(
              'The SQL contains no :name placeholders, but a value was supplied for ":%s"', [LName])
          else
            raise Exception.CreateFmt(
              'The SQL has no parameter named ":%s". Parameters in the SQL: %s',
              [LName, DescribeSqlParams(AQuery)]);
        end;
      end;
    finally
      LArray.Free;
    end;
  end;

  // Every placeholder must have received a value; unbound params are still
  // ftUnknown and cannot be sent to the server.
  LMissingNames := TStringList.Create;
  try
    LMissingNames.Sorted := True;
    LMissingNames.Duplicates := dupIgnore;
    LMissingNames.CaseSensitive := False;
    for I := 0 to AQuery.Params.Count - 1 do
      if AQuery.Params[I].DataType = ftUnknown then
        LMissingNames.Add(AQuery.Params[I].Name);
    if LMissingNames.Count > 0 then
    begin
      LMissing := ':' + string.Join(', :', LMissingNames.ToStringArray);
      raise Exception.CreateFmt(
        'No value provided for SQL parameter(s): %s. Supply them via the params argument, e.g. [{"name":"%s","value":...}]',
        [LMissing, LMissingNames[0]]);
    end;
  finally
    LMissingNames.Free;
  end;
end;

end.
