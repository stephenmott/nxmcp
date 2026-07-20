unit nxmcp.ValueFormat;

/// <summary>
/// Shared helpers for turning JSON values into SQL literal text for the
/// high-level data tools (insert_record / update_records).
///
/// The important case is GUID columns: NexusDB rejects a plain string literal
/// ('...') assigned to or compared against a GUID column with a "Type mismatch"
/// error. The only accepted form is the typed literal GUID '{...}', and the
/// value inside MUST be brace-wrapped (NexusDB parses it with the RTL
/// StringToGUID / CLSIDFromString, which require braces). These helpers look up
/// the target column's field type and emit GUID '{...}' for GUID columns,
/// normalizing the incoming value to the canonical braced form.
/// </summary>

interface

uses
  System.JSON,
  System.Generics.Collections,
  nxsdTypes;

/// <summary>
/// Reads the data dictionary for a table and returns a map of column name
/// (UPPERCASE) -> field type. Caller owns and frees the dictionary.
/// Raises on error (e.g. table not found). Uses ExecuteWithReconnect so a
/// dropped connection is transparently retried.
/// </summary>
function GetTableFieldTypes(const ATableName: string): TDictionary<string, TnxFieldType>;

/// <summary>
/// Validates a GUID string and returns it in canonical braced uppercase form
/// ({XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}). Accepts the value with or without
/// surrounding braces. Raises a clear exception if the value is not a valid GUID.
/// </summary>
function NormalizeGuidLiteral(const AValue: string): string;

/// <summary>
/// Validates a date string and returns it in NexusDB's fixed literal form
/// 'YYYY-MM-DD'. Accepts a bare date or a full date/time (the time portion is
/// ignored), with 'T' or space separators. Raises on an invalid value.
/// </summary>
function NormalizeDateLiteral(const AValue: string): string;

/// <summary>
/// Validates a time string and returns it in NexusDB's fixed literal form
/// 'HH:MM:SS' (or 'HH:MM:SS.fff' when sub-second digits are supplied). Accepts a
/// bare time or a full date/time (the date portion is ignored); a trailing 'Z'
/// or timezone offset is stripped (wall-clock value preserved). Raises on error.
/// </summary>
function NormalizeTimeLiteral(const AValue: string): string;

/// <summary>
/// Validates a date/time string and returns it in NexusDB's fixed timestamp
/// literal form 'YYYY-MM-DD HH:MM:SS' (or with '.fff'). Accepts 'T' or space
/// between date and time, a date-only value (time defaults to 00:00:00), and a
/// trailing 'Z' / timezone offset (stripped; wall-clock preserved). NexusDB
/// requires a SPACE separator, so 'T' is converted. Raises on error.
/// </summary>
function NormalizeTimestampLiteral(const AValue: string): string;

/// <summary>
/// Formats a single JSON value as the SQL literal text to place on the
/// right-hand side of a column assignment or VALUES list.
///   - null   -> NULL
///   - number -> the numeric text verbatim
///   - bool   -> TRUE / FALSE
///   - string -> quoted literal, OR a typed literal when AFieldTypes marks
///               AColumnName as a column NexusDB will not coerce from a plain
///               string: GUID '{...}', DATE '...', TIME '...', TIMESTAMP '...'.
/// AFieldTypes may be nil; in that case typed-column detection is skipped and the
/// value is formatted exactly as before (plain quoted string).
/// </summary>
function FormatJsonValueAsSql(const AColumnName: string; const AValue: TJSONValue;
  const AFieldTypes: TDictionary<string, TnxFieldType>): string;

implementation

uses
  System.SysUtils,
  System.RegularExpressions,
  nxsdDataDictionary,
  nxllException,
  dmnx;

function GetTableFieldTypes(const ATableName: string): TDictionary<string, TnxFieldType>;
var
  LDict: TnxDataDictionary;
  LField: TnxFieldDescriptor;
  I: Integer;
begin
  Result := TDictionary<string, TnxFieldType>.Create;
  try
    LDict := TnxDataDictionary.Create;
    try
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(
            ATableName, nxmodule.TablePassword, LDict));
        end);

      for I := 0 to LDict.FieldsDescriptor.FieldCount - 1 do
      begin
        LField := LDict.FieldsDescriptor.FieldDescriptor[I];
        Result.AddOrSetValue(UpperCase(LField.Name), LField.fdType);
      end;
    finally
      LDict.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function NormalizeGuidLiteral(const AValue: string): string;
var
  LStr: string;
  LGuid: TGUID;
begin
  LStr := Trim(AValue);
  if LStr = '' then
    raise Exception.Create('GUID value cannot be empty');

  // StringToGUID requires the surrounding braces; add them if the caller
  // (or the LLM) supplied a bare GUID.
  if (LStr[1] <> '{') then
    LStr := '{' + LStr + '}';

  try
    LGuid := StringToGUID(LStr);
  except
    on E: EConvertError do
      raise Exception.CreateFmt('Invalid GUID value: "%s"', [AValue]);
  end;

  // Canonical braced uppercase form, exactly how NexusDB stores/returns it.
  Result := GUIDToString(LGuid);
end;

// Returns the integer value of regex capture group AIndex, or ADefault when the
// group did not participate / is empty.
function GroupIntDef(const AMatch: TMatch; AIndex, ADefault: Integer): Integer;
begin
  if (AIndex < AMatch.Groups.Count) and AMatch.Groups[AIndex].Success and
     (AMatch.Groups[AIndex].Value <> '') then
    Result := StrToInt(AMatch.Groups[AIndex].Value)
  else
    Result := ADefault;
end;

// Returns the fractional-seconds capture (group AIndex) as a 3-digit millisecond
// string using ISO semantics ('.5' -> '500', '.12' -> '120', '.1234' -> '123').
// AHasMs reports whether a fraction was present at all.
function MsString3(const AMatch: TMatch; AIndex: Integer; out AHasMs: Boolean): string;
begin
  AHasMs := (AIndex < AMatch.Groups.Count) and AMatch.Groups[AIndex].Success and
            (AMatch.Groups[AIndex].Value <> '');
  if AHasMs then
    Result := Copy(AMatch.Groups[AIndex].Value + '000', 1, 3)
  else
    Result := '';
end;

function NormalizeDateLiteral(const AValue: string): string;
var
  LMatch: TMatch;
  Y, Mo, D: Integer;
  LDummy: TDateTime;
begin
  // Date, optionally followed by a time portion (ignored).
  LMatch := TRegEx.Match(Trim(AValue), '^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T].*)?$');
  if not LMatch.Success then
    raise Exception.CreateFmt('Invalid date value: "%s" (expected YYYY-MM-DD)', [AValue]);

  Y := GroupIntDef(LMatch, 1, 0);
  Mo := GroupIntDef(LMatch, 2, 0);
  D := GroupIntDef(LMatch, 3, 0);
  if not TryEncodeDate(Y, Mo, D, LDummy) then
    raise Exception.CreateFmt('Invalid date value: "%s"', [AValue]);

  Result := Format('%.4d-%.2d-%.2d', [Y, Mo, D]);
end;

function NormalizeTimeLiteral(const AValue: string): string;
var
  LMatch: TMatch;
  H, Mi, S: Integer;
  LMs: string;
  LHasMs: Boolean;
  LDummy: TDateTime;
begin
  // Optional leading date (ignored), time, optional fraction, optional 'Z'/offset.
  LMatch := TRegEx.Match(Trim(AValue),
    '^(?:\d{4}-\d{1,2}-\d{1,2}[ T])?(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?(?:\.(\d{1,9}))?\s*(?:[Zz]|[+-]\d{2}:?\d{2})?$');
  if not LMatch.Success then
    raise Exception.CreateFmt('Invalid time value: "%s" (expected HH:MM:SS)', [AValue]);

  H := GroupIntDef(LMatch, 1, 0);
  Mi := GroupIntDef(LMatch, 2, 0);
  S := GroupIntDef(LMatch, 3, 0);
  LMs := MsString3(LMatch, 4, LHasMs);
  if not TryEncodeTime(H, Mi, S, StrToIntDef(LMs, 0), LDummy) then
    raise Exception.CreateFmt('Invalid time value: "%s"', [AValue]);

  Result := Format('%.2d:%.2d:%.2d', [H, Mi, S]);
  if LHasMs then
    Result := Result + '.' + LMs;
end;

function NormalizeTimestampLiteral(const AValue: string): string;
var
  LMatch: TMatch;
  Y, Mo, D, H, Mi, S: Integer;
  LMs: string;
  LHasMs: Boolean;
  LDummy: TDateTime;
begin
  // Date, optional [ T] + time + fraction, optional 'Z'/offset. NexusDB requires
  // a space between date and time, which the canonical output below produces.
  LMatch := TRegEx.Match(Trim(AValue),
    '^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?(?:\.(\d{1,9}))?)?\s*(?:[Zz]|[+-]\d{2}:?\d{2})?$');
  if not LMatch.Success then
    raise Exception.CreateFmt('Invalid date/time value: "%s" (expected YYYY-MM-DD HH:MM:SS)', [AValue]);

  Y := GroupIntDef(LMatch, 1, 0);
  Mo := GroupIntDef(LMatch, 2, 0);
  D := GroupIntDef(LMatch, 3, 0);
  H := GroupIntDef(LMatch, 4, 0);
  Mi := GroupIntDef(LMatch, 5, 0);
  S := GroupIntDef(LMatch, 6, 0);
  LMs := MsString3(LMatch, 7, LHasMs);
  if (not TryEncodeDate(Y, Mo, D, LDummy)) or
     (not TryEncodeTime(H, Mi, S, StrToIntDef(LMs, 0), LDummy)) then
    raise Exception.CreateFmt('Invalid date/time value: "%s"', [AValue]);

  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d', [Y, Mo, D, H, Mi, S]);
  if LHasMs then
    Result := Result + '.' + LMs;
end;

function FormatJsonValueAsSql(const AColumnName: string; const AValue: TJSONValue;
  const AFieldTypes: TDictionary<string, TnxFieldType>): string;
var
  LType: TnxFieldType;
begin
  if AValue is TJSONNull then
    Exit('NULL');

  if AValue is TJSONNumber then
    Exit(AValue.Value);

  if AValue is TJSONBool then
  begin
    if TJSONBool(AValue).AsBoolean then
      Exit('TRUE')
    else
      Exit('FALSE');
  end;

  // String value. NexusDB will not coerce a plain string literal into a GUID,
  // DATE, TIME or DATETIME column (it raises a type mismatch); those require the
  // typed literal form. Detect the target column type and emit it; everything
  // else stays a plain quoted string literal.
  if Assigned(AFieldTypes) and
     AFieldTypes.TryGetValue(UpperCase(AColumnName), LType) then
  begin
    case LType of
      nxtGuid:     Exit('GUID ' + QuotedStr(NormalizeGuidLiteral(AValue.Value)));
      nxtDate:     Exit('DATE ' + QuotedStr(NormalizeDateLiteral(AValue.Value)));
      nxtTime:     Exit('TIME ' + QuotedStr(NormalizeTimeLiteral(AValue.Value)));
      nxtDateTime: Exit('TIMESTAMP ' + QuotedStr(NormalizeTimestampLiteral(AValue.Value)));
    end;
  end;

  Result := QuotedStr(AValue.Value);
end;

end.
