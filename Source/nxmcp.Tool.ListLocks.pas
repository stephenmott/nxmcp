unit nxmcp.Tool.ListLocks;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the list_locks tool
  /// </summary>
  TListLocksParams = class
  private
    FLockType: string;
    FTableName: string;
    FMaxRows: Integer;
  public
    [Optional]
    [SchemaDescription('Which locks to report: "table" (#TABLE_LOCKS - record and cursor level), ' +
      '"transaction" (#TRANSACTION_LOCKS - transaction level), or "all" (default: both)')]
    property LockType: string read FLockType write FLockType;

    [Optional]
    [SchemaDescription('Only report locks on this table (case-insensitive exact match). ' +
      'Empty (default) reports locks on all tables.')]
    property TableName: string read FTableName write FTableName;

    [Optional]
    [SchemaDescription('Maximum number of lock rows to return per lock table (default: 500, max: 10000)')]
    property MaxRows: Integer read FMaxRows write FMaxRows;
  end;

  /// <summary>
  /// MCP Tool that reports the live lock state from the server's lock meta tables.
  /// Both meta tables were added in a later NexusDB release, so a server that does
  /// not have them is reported as unavailable rather than raising.
  /// </summary>
  TListLocksTool = class(TMCPToolBase<TListLocksParams>)
  private
    function ServerKnowsMetaTable(const AMetaTableName: string): Boolean;
    function CollectLocks(const AMetaTableName, ATableFilter: string;
      AMaxRows: Integer): TJSONObject;
  protected
    function ExecuteWithParams(const Params: TListLocksParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.Math,
  Data.DB,
  DataSet.Serialize,
  MCPServer.Registration,
  dmnx;

const
  // Reserved (virtual) meta tables, populated on demand by the server engine.
  cTableLocks       = '#TABLE_LOCKS';
  cTransactionLocks = '#TRANSACTION_LOCKS';

  // Every lock meta table names the locked table in this column; the filter and
  // the JSON row keys both derive from it (dataset.serialize lower-camel-cases
  // the field names, so it surfaces as "tableName").
  cTableNameField   = 'TABLE_NAME';

{ TListLocksTool }

constructor TListLocksTool.Create;
begin
  inherited;
  FName := 'list_locks';
  FTitle := 'List Locks';
  FDescription := 'Report the live lock state of the NexusDB server from its lock meta tables: ' +
                  '#TABLE_LOCKS (record and cursor level locks - table, lock type, record ' +
                  'reference, session, whether the request is still waiting) and ' +
                  '#TRANSACTION_LOCKS (transaction level locks - table, shared/exclusive, lock ' +
                  'state, transaction level, how long it has been held). Use it to diagnose ' +
                  'contention, find long-held locks, or inspect the wait queue. ' +
                  'These meta tables only exist on newer NexusDB releases: against an older ' +
                  'server the tool does not fail but returns "available": false with an ' +
                  'explanation for that lock table.';
end;

/// <summary>
/// Ask the server which reserved tables it knows. #META lists exactly the meta
/// tables the *server* implements, which is what distinguishes "this build has
/// no lock meta tables" from a genuine failure reading them. Checking the
/// constants compiled into nxmcp would be wrong: in remote mode the SQL engine
/// lives in the NXserver process, which may be older or newer than this client.
/// </summary>
function TListLocksTool.ServerKnowsMetaTable(const AMetaTableName: string): Boolean;
var
  LFound: Boolean;
begin
  LFound := False;
  try
    nxmodule.ExecuteWithReconnect(
      procedure
      begin
        LFound := False;
        nxmodule.nxQuery1.Close;
        nxmodule.nxQuery1.Params.Clear;
        nxmodule.nxQuery1.SQL.Text := 'SELECT METATABLE_NAME FROM #META';
        nxmodule.nxQuery1.Open;
        try
          while not nxmodule.nxQuery1.Eof do
          begin
            if SameText(Trim(nxmodule.nxQuery1.Fields[0].AsString), AMetaTableName) then
            begin
              LFound := True;
              Break;
            end;
            nxmodule.nxQuery1.Next;
          end;
        finally
          nxmodule.nxQuery1.Close;
        end;
      end);
  except
    // #META itself is unreadable, so this probe cannot answer the question.
    // Report "known" so the caller re-raises the original, more informative
    // error instead of blaming the server version for an unrelated problem.
    Exit(True);
  end;
  Result := LFound;
end;

/// <summary>
/// Read one lock meta table into a JSON section. Returns a section with
/// "available": false instead of raising when the server does not have it.
/// </summary>
function TListLocksTool.CollectLocks(const AMetaTableName, ATableFilter: string;
  AMaxRows: Integer): TJSONObject;
var
  LRowCount: Integer;
  LTruncated: Boolean;
  LTableField: TField;
  LIncludeRow: Boolean;
  LOpenAttempted: Boolean;
  LReadOpened: Boolean;
  LReadError: string;
  LReadResult: TJSONObject;
  LReadRows: TJSONArray;
begin
  LOpenAttempted := False;
  LReadOpened := False;
  LReadResult := nil;
  LReadRows := nil;
  try
    try
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          // This also makes the action self-contained if the retry policy ever
          // invokes it after a partially completed attempt.
          if Assigned(LReadResult) then
          begin
            LReadResult.Free;
            LReadResult := nil;
          end;
          if Assigned(LReadRows) then
          begin
            LReadRows.Free;
            LReadRows := nil;
          end;
          LOpenAttempted := False;
          LReadOpened := False;
          nxmodule.nxQuery1.Close;
          try
            // Drop bindings left over from an earlier statement: setting
            // SQL.Text carries old values onto same-named params of the new
            // statement.
            nxmodule.nxQuery1.Params.Clear;
            nxmodule.nxQuery1.SQL.Text := 'SELECT * FROM ' + AMetaTableName;
            LOpenAttempted := True;
            nxmodule.nxQuery1.Open;
            LReadOpened := True;

            LReadResult := TJSONObject.Create;
            LReadRows := TJSONArray.Create;
            LRowCount := 0;
            LTruncated := False;
            LTableField := nxmodule.nxQuery1.FindField(cTableNameField);
            // A filter we cannot apply would silently report "no locks", which
            // reads like an all-clear. Say so instead.
            if (ATableFilter <> '') and not Assigned(LTableField) then
              raise Exception.Create(AMetaTableName + ' has no ' + cTableNameField +
                ' column on this server; retry without tableName to see all locks.');

            nxmodule.nxQuery1.First;
            while not nxmodule.nxQuery1.Eof do
            begin
              LIncludeRow := ATableFilter = '';
              if not LIncludeRow then
                LIncludeRow := SameText(Trim(LTableField.AsString), ATableFilter);
              if LIncludeRow then
              begin
                if LRowCount >= AMaxRows then
                begin
                  LTruncated := True;
                  Break;
                end;
                LReadRows.AddElement(nxmodule.nxQuery1.ToJSONObject);
                Inc(LRowCount);
              end;
              nxmodule.nxQuery1.Next;
            end;

            LReadResult.AddPair('metaTable', AMetaTableName);
            LReadResult.AddPair('available', TJSONBool.Create(True));
            LReadResult.AddPair('lockCount', TJSONNumber.Create(LRowCount));
            LReadResult.AddPair('truncated', TJSONBool.Create(LTruncated));
            // Ownership of LReadRows transfers to LReadResult here.
            LReadResult.AddPair('locks', LReadRows);
            LReadRows := nil;
          finally
            nxmodule.nxQuery1.Close;
          end;
        end,
        procedure(E: Exception)
        begin
          // ExecuteWithReconnect calls this before retiring a poisoned session;
          // do not carry objects made against the old cursor into the retry.
          if Assigned(LReadResult) then
          begin
            LReadResult.Free;
            LReadResult := nil;
          end;
          if Assigned(LReadRows) then
          begin
            LReadRows.Free;
            LReadRows := nil;
          end;
        end);
    except
      on E: Exception do
      begin
        // Only an unknown meta table is reported gracefully. A filter-column
        // problem, permission failure, dead connection, or other read error
        // remains an error unless #META explicitly says the table is absent.
        LReadError := E.Message;
        if Assigned(LReadResult) then
        begin
          LReadResult.Free;
          LReadResult := nil;
        end;
        if Assigned(LReadRows) then
        begin
          LReadRows.Free;
          LReadRows := nil;
        end;
        if not LOpenAttempted or LReadOpened then
          raise;
        if ServerKnowsMetaTable(AMetaTableName) then
          raise Exception.Create('Failed to read ' + AMetaTableName + ': ' + LReadError);

        Result := TJSONObject.Create;
        try
          Result.AddPair('metaTable', AMetaTableName);
          Result.AddPair('available', TJSONBool.Create(False));
          Result.AddPair('message',
            'This NexusDB server does not provide ' + AMetaTableName + '. The lock meta ' +
            'tables were added in a later NexusDB release - upgrade the server (in ' +
            'embedded mode: rebuild nxmcp against a newer NexusDB library) to inspect ' +
            'locks. Lock conflicts are still reported in full detail in the error ' +
            'message raised when a lock cannot be granted.');
          Result.AddPair('serverError', LReadError);
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    end;
    Result := LReadResult;
    LReadResult := nil;
  finally
    if Assigned(LReadResult) then
    begin
      LReadResult.Free;
      LReadResult := nil;
    end;
    if Assigned(LReadRows) then
    begin
      LReadRows.Free;
      LReadRows := nil;
    end;
  end;
end;

function TListLocksTool.ExecuteWithParams(const Params: TListLocksParams): string;
var
  LResultObj: TJSONObject;
  LLockType: string;
  LWantTable: Boolean;
  LWantTransaction: Boolean;
  LFilter: string;
  LMaxRows: Integer;
begin
  LLockType := LowerCase(Trim(Params.LockType));
  if LLockType = '' then
    LLockType := 'all';

  LWantTable := (LLockType = 'all') or (LLockType = 'table');
  LWantTransaction := (LLockType = 'all') or (LLockType = 'transaction');

  // Reject a typo instead of silently reporting nothing at all.
  if not LWantTable and not LWantTransaction then
    raise Exception.Create('Unknown lockType "' + Params.LockType +
      '" (valid values: table, transaction, all)');

  if Params.MaxRows > 0 then
    LMaxRows := Min(Params.MaxRows, 10000)
  else
    LMaxRows := 500;

  LFilter := Trim(Params.TableName);

  // The meta tables are read through the SQL engine, which needs an open
  // database - EnsureConnection, not EnsureSession.
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('mode', Tnxmodule.ModeToStr(nxmodule.ServerMode));
    if LFilter <> '' then
      LResultObj.AddPair('tableFilter', LFilter);
    if LWantTable then
      LResultObj.AddPair('tableLocks', CollectLocks(cTableLocks, LFilter, LMaxRows));
    if LWantTransaction then
      LResultObj.AddPair('transactionLocks', CollectLocks(cTransactionLocks, LFilter, LMaxRows));
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('list_locks',
    function: IMCPTool
    begin
      Result := TListLocksTool.Create;
    end
  );

end.
