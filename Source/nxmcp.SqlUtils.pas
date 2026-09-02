unit nxmcp.SqlUtils;

interface

uses
  System.JSON, Classes;

/// <summary>
/// Strips NexusDB statement switches (#T, #I, #S, #L, #B, #V) from the
/// beginning of a SQL string and returns the remaining SQL keyword.
/// Switches: #T nnn, #I+/-, #S+/-, #L+/-, #B+/-, #V+/-
///
/// The engine's sixth prefix switch, #OPT::&lt;group&gt;::&lt;name&gt;='&lt;value&gt;', is
/// deliberately NOT stripped. It sets a server-side option, and its group may be
/// SESSION or DATABASE - i.e. state outliving the statement. Leaving it in means
/// AnalyzeSql sees #OPT as the first token, reports skOther, and every tool that
/// demands a SELECT rejects the input. nxmcp emits #OPT itself where it needs it
/// (explain_query, statement scope only); callers must not be able to smuggle it
/// through the SQL of a read-only tool.
/// </summary>
function StripSwitches(const ASql: string): string;

type
  /// <summary>
  /// What a statement starts with, determined from its first meaningful token.
  /// skOther covers DDL and everything else that is not one of the four DML verbs.
  /// </summary>
  TnxSqlKind = (skUnparsable, skEmpty, skSelect, skInsert, skUpdate, skDelete, skOther);

  /// <summary>
  /// Everything the guards need to know about a statement, from a single pass of
  /// NexusDB's own SQL lexer (TnxSQLTokenizer).
  /// </summary>
  TnxSqlFacts = record
    Kind: TnxSqlKind;
    /// True when the text holds exactly one statement. A single trailing
    /// semicolon is fine; anything after it is a second statement.
    IsSingle: Boolean;
    /// True when a standalone INTO clause is present. SELECT ... INTO creates
    /// and populates a table, so it is a write dressed up as a query.
    HasInto: Boolean;
  end;

/// <summary>
/// Analyses ASql (switches are stripped internally) with NexusDB's own SQL
/// tokenizer, so comments, string literals and quoted identifiers are classified
/// by the same lexer the server uses instead of being re-guessed here. A ';' in
/// a literal, or a column quoted as "into", cannot produce a false positive.
/// Anything the lexer cannot tokenize comes back as skUnparsable with
/// IsSingle=False, so callers fail closed.
/// </summary>
function AnalyzeSql(const ASql: string): TnxSqlFacts;

/// <summary>
/// Returns True if ASql is exactly one statement (see TnxSqlFacts.IsSingle).
/// Subselects pass: they add no top-level semicolon.
/// </summary>
function IsSingleStatement(const ASql: string): Boolean;

/// <summary>
/// Returns True if ASql (after stripping switches) is a single SELECT statement
/// with no INTO clause - i.e. it only reads.
/// </summary>
function IsSelectStatement(const ASql: string): Boolean;

/// <summary>
/// Raises unless ASql is exactly one statement. AWhat names the offending input
/// in the message (e.g. 'SQL statement', 'WHERE clause').
/// </summary>
procedure CheckSingleStatement(const ASql, AWhat: string);

/// <summary>
/// Raises unless ATableName is a valid NexusDB table name, using the engine's own
/// nxCheckValidTableName. Accepts everything NexusDB accepts - meta tables
/// (#TABLES), memory/temp tables (&lt;name&gt;), child tables (parent:child) and
/// system tables - and rejects the characters that are not legal in an
/// identifier at all, notably '"' and ';'. That is what makes concatenating the
/// name into SQL safe: NexusDB has no escape syntax for a quote inside a quoted
/// identifier (SELECT 1 AS "a""b" is a syntax error), so rejecting is both the
/// only available option and a complete one.
/// </summary>
procedure CheckTableName(const ATableName: string);

/// <summary>
/// Raises unless AIdent is a valid NexusDB identifier (column, index, ...).
/// AWhat names it in the error message.
/// </summary>
procedure CheckIdentifier(const AIdent, AWhat: string);

/// <summary>
/// Converts a TStrings log (e.g. TnxQuery.Log) into a TJSONArray of strings.
/// Caller owns the returned array (typically added to a parent JSON object which takes ownership).
/// </summary>
function LogToJSONArray(ALog: TStrings): TJSONArray;

implementation

uses
  System.SysUtils, System.Character,
  // NexusDB's own SQL lexer - the same one the server parses with - plus the
  // engine's identifier validators, so nxmcp never has to re-guess either.
  nxSQLTok, CocoaBaseW,
  nxllUtils, nxllBde, nxllException, nxsdServerEngine;

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

function AnalyzeSql(const ASql: string): TnxSqlFacts;
var
  LSql: string;
  LTokenizer: TnxSQLTokenizer;
  LTokens: TTokenList;
  LOk: Boolean;
  I, LType: Integer;
  LSeenSemicolon: Boolean;
begin
  Result.Kind := skUnparsable;
  Result.IsSingle := False;
  Result.HasInto := False;

  // The #T/#I/#S/#L/#B/#V prefixes are NexusDB statement switches, not SQL, and
  // would only confuse the lexer.
  LSql := StripSwitches(ASql).Trim;
  if LSql = '' then
  begin
    Result.Kind := skEmpty;
    Exit;
  end;

  LTokens := nil;
  LTokenizer := TnxSQLTokenizer.Create;
  try
    // Comments and whitespace excluded: what is left is only meaningful tokens.
    LOk := LTokenizer.Tokenize(PWideChar(LSql), Length(LSql), False, False, LTokens);
    if not LOk or not Assigned(LTokens) then
      Exit;

    Result.IsSingle := True;
    LSeenSemicolon := False;

    for I := 0 to LTokens.TokenCount - 1 do
    begin
      LType := LTokens.TokenType[I];
      if LType = TOK_eof then
        Break;

      // Anything at all after a semicolon is a second statement.
      if LSeenSemicolon then
      begin
        Result.IsSingle := False;
        Break;
      end;

      if LType = TOK__59_ then
        LSeenSemicolon := True
      else
      begin
        if LType = TOK_INTO then
          Result.HasInto := True;
        // First meaningful token decides the kind.
        if Result.Kind = skUnparsable then
          case LType of
            TOK_SELECT: Result.Kind := skSelect;
            TOK_INSERT: Result.Kind := skInsert;
            TOK_UPDATE: Result.Kind := skUpdate;
            TOK_DELETE: Result.Kind := skDelete;
          else
            Result.Kind := skOther;
          end;
      end;
    end;

    // A lexable statement that produced no meaningful token at all.
    if Result.Kind = skUnparsable then
      Result.Kind := skEmpty;
  finally
    LTokens.Free;
    LTokenizer.Free;
  end;
end;

function IsSingleStatement(const ASql: string): Boolean;
begin
  Result := AnalyzeSql(ASql).IsSingle;
end;

function IsSelectStatement(const ASql: string): Boolean;
var
  LFacts: TnxSqlFacts;
begin
  LFacts := AnalyzeSql(ASql);
  Result := (LFacts.Kind = skSelect) and LFacts.IsSingle and not LFacts.HasInto;
end;

procedure CheckSingleStatement(const ASql, AWhat: string);
begin
  if not IsSingleStatement(ASql) then
    raise Exception.Create(AWhat + ' must be a single statement - a second ' +
      'statement after a semicolon is not allowed. Use execute_sql or ' +
      'batch_execute to run several statements.');
end;

procedure CheckTableName(const ATableName: string);
begin
  if Trim(ATableName) = '' then
    raise Exception.Create('Table name cannot be empty');
  try
    // aEmptyAsUnknown=False (empty is handled above), aAllowSystem=True so the
    // dev tools keep reaching meta and system tables.
    nxCheck(nxCheckValidTableName(ATableName, False, True));
  except
    on E: Exception do
      raise Exception.Create('Invalid table name "' + ATableName + '": ' + E.Message);
  end;
end;

procedure CheckIdentifier(const AIdent, AWhat: string);
begin
  if Trim(AIdent) = '' then
    raise Exception.Create(AWhat + ' cannot be empty');
  try
    nxCheck(nxCheckValidIdent(AIdent, DBIERR_INVALIDFIELDNAME, False, True));
  except
    on E: Exception do
      raise Exception.Create('Invalid ' + AWhat + ' "' + AIdent + '": ' + E.Message);
  end;
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
