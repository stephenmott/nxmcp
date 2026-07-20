unit nxmcp.FieldTypes;

/// <summary>
/// Shared field type conversion utilities using RTTI.
/// Converts between user-facing type name strings and TnxFieldType enum values.
/// </summary>

interface

uses
  nxsdTypes;

/// <summary>
/// Converts a user-facing type name string to a TnxFieldType.
/// Case-insensitive. Supports both canonical names (e.g. 'Int32') and
/// friendly aliases (e.g. 'Integer'). Raises Exception for unknown types.
/// nxtInterval is explicitly excluded.
/// </summary>
function StringToFieldType(const AType: string): TnxFieldType;

/// <summary>
/// Converts a TnxFieldType to its canonical user-facing string name.
/// Returns the friendly alias where one exists (e.g. nxtInt32 -> 'Integer').
/// For types without an alias, strips the 'nxt' prefix from the enum name.
/// </summary>
function FieldTypeToString(AFieldType: TnxFieldType): string;

/// <summary>
/// Returns a comma-separated list of all supported type names
/// for use in tool descriptions and documentation.
/// </summary>
function AllFieldTypeNames: string;

implementation

uses
  System.SysUtils,
  System.TypInfo;

const
  NXT_PREFIX = 'nxt';

type
  TFieldTypeAlias = record
    Name: string;        // Lowercase for matching
    DisplayName: string; // PascalCase for display
    FieldType: TnxFieldType;
  end;

const
  /// Aliases: user-friendly names that don't match the nxt+Name pattern.
  /// These are checked first in StringToFieldType and used as display names
  /// in FieldTypeToString.
  AliasCount = 6;
  Aliases: array[0..AliasCount - 1] of TFieldTypeAlias = (
    (Name: 'integer';  DisplayName: 'Integer';  FieldType: nxtInt32),
    (Name: 'word';     DisplayName: 'Word';      FieldType: nxtWord16),
    (Name: 'float';    DisplayName: 'Float';     FieldType: nxtDouble),
    (Name: 'memo';     DisplayName: 'Memo';      FieldType: nxtBlobMemo),
    (Name: 'graphic';  DisplayName: 'Graphic';   FieldType: nxtBlobGraphic),
    (Name: 'widememo'; DisplayName: 'WideMemo';  FieldType: nxtBlobWideMemo)
  );

function StringToFieldType(const AType: string): TnxFieldType;
var
  LType: string;
  LEnumVal: Integer;
  I: Integer;
begin
  LType := LowerCase(Trim(AType));

  // 1. Check alias table (handles Integer, Word, Float, Memo, Graphic, WideMemo)
  for I := 0 to AliasCount - 1 do
    if LType = Aliases[I].Name then
      Exit(Aliases[I].FieldType);

  // 2. Try RTTI: prepend 'nxt' prefix and look up enum value
  LEnumVal := GetEnumValue(TypeInfo(TnxFieldType), NXT_PREFIX + AType);
  if LEnumVal >= 0 then
  begin
    Result := TnxFieldType(LEnumVal);
    // Block nxtInterval - not currently used
    if Result = nxtInterval then
      raise Exception.Create('Field type Interval is not supported');
    Exit;
  end;

  raise Exception.CreateFmt('Unknown field type: %s', [AType]);
end;

function FieldTypeToString(AFieldType: TnxFieldType): string;
var
  I: Integer;
begin
  // 1. Check alias table for friendly display names
  for I := 0 to AliasCount - 1 do
    if AFieldType = Aliases[I].FieldType then
      Exit(Aliases[I].DisplayName);

  // 2. Fall back to RTTI: get enum name and strip 'nxt' prefix
  Result := GetEnumName(TypeInfo(TnxFieldType), Ord(AFieldType));
  if Result.StartsWith(NXT_PREFIX, True) then
    Delete(Result, 1, Length(NXT_PREFIX));
end;

function AllFieldTypeNames: string;
var
  LFieldType: TnxFieldType;
  LName: string;
  LFirst: Boolean;
begin
  Result := '';
  LFirst := True;
  for LFieldType := Low(TnxFieldType) to High(TnxFieldType) do
  begin
    if LFieldType = nxtInterval then
      Continue;
    LName := FieldTypeToString(LFieldType);
    if not LFirst then
      Result := Result + ', ';
    Result := Result + LName;
    LFirst := False;
  end;
end;

end.
