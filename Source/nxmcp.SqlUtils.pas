unit nxmcp.SqlUtils;

interface

uses
  System.JSON, Classes;

/// <summary>
/// Strips NexusDB statement switches (#T, #I, #S, #L, #B, #V) from the
/// beginning of a SQL string and returns the remaining SQL keyword.
/// Switches: #T nnn, #I+/-, #S+/-, #L+/-, #B+/-, #V+/-
/// </summary>
function StripSwitches(const ASql: string): string;

/// <summary>
/// Returns True if the SQL statement (after stripping switches) starts with SELECT.
/// </summary>
function IsSelectStatement(const ASql: string): Boolean;

/// <summary>
/// Converts a TStrings log (e.g. TnxQuery.Log) into a TJSONArray of strings.
/// Caller owns the returned array (typically added to a parent JSON object which takes ownership).
/// </summary>
function LogToJSONArray(ALog: TStrings): TJSONArray;

implementation

uses
  System.SysUtils, System.Character;

function StripSwitches(const ASql: string): string;
var
  S: string;
  Len: Integer;
  I: Integer;
begin
  S := ASql.TrimLeft;
  Len := Length(S);

  while (Len >= 2) and (S[1] = '#') do
  begin
    // Check for known switch letters
    if not CharInSet(UpCase(S[2]), ['T', 'I', 'S', 'L', 'B', 'V']) then
      Break;

    // #T expects a numeric argument: #T 5000
    if UpCase(S[2]) = 'T' then
    begin
      I := 3;
      // Skip whitespace between #T and the number
      while (I <= Len) and S[I].IsWhiteSpace do
        Inc(I);
      // Skip digits
      while (I <= Len) and S[I].IsDigit do
        Inc(I);
    end
    else
    begin
      // Other switches: #X+ or #X- (toggle)
      I := 3;
      if (I <= Len) and CharInSet(S[I], ['+', '-']) then
        Inc(I);
    end;

    // Skip trailing whitespace after the switch
    while (I <= Len) and S[I].IsWhiteSpace do
      Inc(I);

    S := Copy(S, I, Len - I + 1);
    Len := Length(S);
  end;

  Result := S;
end;

function IsSelectStatement(const ASql: string): Boolean;
begin
  Result := StripSwitches(ASql).ToUpper.StartsWith('SELECT');
end;

function LogToJSONArray(ALog: TStrings): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to ALog.Count - 1 do
    Result.Add(ALog[I]);
end;

end.
