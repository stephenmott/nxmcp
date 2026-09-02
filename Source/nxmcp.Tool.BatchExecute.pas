unit nxmcp.Tool.BatchExecute;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the batch_execute tool
  /// </summary>
  TBatchExecuteParams = class
  private
    FStatements: string;
    FSnapshot: Boolean;
    FLog: Boolean;
    FVerboseLog: Boolean;
  public
    [SchemaDescription('JSON array of SQL statements to execute, e.g. ["SELECT * FROM...", "INSERT INTO...", "UPDATE..."]')]
    property Statements: string read FStatements write FStatements;

    [SchemaDescription('Use snapshot transaction for read consistency (default: false)')]
    property Snapshot: Boolean read FSnapshot write FSnapshot;

    [Optional]
    [SchemaDescription('Enable query log (#L+) to capture execution plan summary for each statement')]
    property Log: Boolean read FLog write FLog;

    [Optional]
    [SchemaDescription('Enable verbose log (#V+) to capture full optimizer internals for each statement')]
    property VerboseLog: Boolean read FVerboseLog write FVerboseLog;
  end;

  /// <summary>
  /// MCP Tool that executes multiple SQL statements in a single transaction.
  /// All statements succeed or all are rolled back.
  /// </summary>
  TBatchExecuteTool = class(TMCPToolBase<TBatchExecuteParams>)
  protected
    function ExecuteWithParams(const Params: TBatchExecuteParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.Generics.Collections,
  Data.DB,
  DataSet.Serialize,
  MCPServer.Registration,
  nxmcp.SqlUtils,
  dmnx;

{ TBatchExecuteTool }

constructor TBatchExecuteTool.Create;
begin
  inherited;
  FName := 'batch_execute';
  FTitle := 'Batch Execute SQL';
  FDescription := 'Execute multiple SQL statements in a single transaction. ' +
                  'Supports SELECT, INSERT, UPDATE, DELETE. All statements succeed together or all are rolled back. ' +
                  'Use snapshot=true for consistent point-in-time reads across multiple SELECTs. ' +
                  'Statement switches (#T timeout, #I- no index, #S- no simplify) can be prefixed to individual statements.';
end;

function TBatchExecuteTool.ExecuteWithParams(const Params: TBatchExecuteParams): string;
var
  LResultObj: TJSONObject;
  LResultsArray: TJSONArray;
  LStatementsArray: TJSONArray;
  LStatementResult: TJSONObject;
  LStatement: string;
  LSql: string;
  LSqlUpper: string;
  LRowsAffected: Integer;
  LTotalRowsAffected: Integer;
  LExecutedCount: Integer;
  LIsSelect: Boolean;
  LHasLog: Boolean;
  LDataArray: TJSONArray;
  I: Integer;
  LTransactionStarted: Boolean;
  LTransactionAttempted: Boolean;
  LRollbackConfirmed: Boolean;
  LSessionPoisoned: Boolean;
  LSessionRetired: Boolean;
  LErrorMessage: string;
  LFailureLog: TJSONArray;
begin
  // Validate parameters
  if Trim(Params.Statements) = '' then
    raise Exception.Create('Statements array cannot be empty');

  // Parse JSON array of statements
  try
    LStatementsArray := TJSONObject.ParseJSONValue(Params.Statements) as TJSONArray;
  except
    on E: Exception do
      raise Exception.Create('Invalid JSON array for statements: ' + E.Message);
  end;

  if not Assigned(LStatementsArray) then
    raise Exception.Create('Statements must be a valid JSON array');

  if LStatementsArray.Count = 0 then
  begin
    LStatementsArray.Free;
    raise Exception.Create('Statements array cannot be empty');
  end;

  // Check connection (transparently reconnects if dropped).
  // Note: comm-lost AFTER the transaction starts is intentionally not retried —
  // the existing rollback path below surfaces a clean error to the caller.
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
  begin
    LStatementsArray.Free;
    raise Exception.Create('Not connected to NexusDB');
  end;

  LResultObj := TJSONObject.Create;
  LResultsArray := TJSONArray.Create;
  LFailureLog := nil;
  LTotalRowsAffected := 0;
  LExecutedCount := 0;
  LTransactionStarted := False;
  LTransactionAttempted := False;

  // Determine if logging is requested. Set before the try so the except handler
  // (which runs even if StartTransaction itself fails) never reads it uninitialized.
  LHasLog := Params.VerboseLog or Params.Log;

  try
    try
      // A batch must never be replayed: once the transaction starts, a
      // reconnect-and-retry could execute writes a second time.  The no-retry
      // policy still retires a poisoned session on a timeout/communication
      // failure, without replaying the action.
      LTransactionAttempted := True;
      nxmodule.ExecuteWithoutRetry(
        procedure
        begin
          nxmodule.nxDatabase1.StartTransaction(Params.Snapshot);
        end);
      LTransactionStarted := True;

      // Execute each statement
      for I := 0 to LStatementsArray.Count - 1 do
      begin
        LStatement := LStatementsArray.Items[I].Value;
        LSqlUpper := StripSwitches(LStatement).ToUpper;
        LIsSelect := LSqlUpper.StartsWith('SELECT');

        // Prepend log switch if requested
        LSql := LStatement;
        if Params.VerboseLog then
          LSql := '#V+ ' + LSql
        else if Params.Log then
          LSql := '#L+ ' + LSql;

        LStatementResult := nil;
        LDataArray := nil;
        nxmodule.ExecuteWithoutRetry(
          procedure
          begin
            try
              try
                nxmodule.nxQuery1.Close;
                nxmodule.nxQuery1.SQL.Text := LSql;

                // Record result for this statement
                LStatementResult := TJSONObject.Create;
                LStatementResult.AddPair('index', TJSONNumber.Create(I));
                LStatementResult.AddPair('statement', Copy(LSqlUpper, 1, Pos(' ', LSqlUpper + ' ') - 1));

                if LIsSelect then
                begin
                // SELECT: Open and return data.  If reading fails, make a
                // best-effort close while preserving the original exception.
                try
                  nxmodule.nxQuery1.Open;
                  LDataArray := nxmodule.nxQuery1.ToJSONArray;
                  LStatementResult.AddPair('rowCount', TJSONNumber.Create(nxmodule.nxQuery1.RecordCount));
                  LStatementResult.AddPair('data', LDataArray);
                  LDataArray := nil;

                  // Include log output if requested
                  if LHasLog then
                    LStatementResult.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));
                except
                  on E: Exception do
                  begin
                    try
                      nxmodule.nxQuery1.Close;
                    except
                      // Preserve the statement/read failure.
                    end;
                    raise;
                  end;
                end;
                nxmodule.nxQuery1.Close;
                end
                else
                begin
                // Non-SELECT: ExecSQL and return rowsAffected
                nxmodule.nxQuery1.ExecSQL;
                LRowsAffected := nxmodule.nxQuery1.RowsAffected;
                LStatementResult.AddPair('rowsAffected', TJSONNumber.Create(LRowsAffected));
                Inc(LTotalRowsAffected, LRowsAffected);

                // Include log output if requested
                if LHasLog then
                  LStatementResult.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));
                end;

                LResultsArray.AddElement(LStatementResult);
                LStatementResult := nil;
                Inc(LExecutedCount);
              except
                on E: Exception do
                begin
                  // Snapshot diagnostics before ExecuteWithoutRetry retires a
                  // poisoned session and rebuilds nxQuery1.
                  if LHasLog and (nxmodule.nxQuery1.Log.Count > 0) then
                  begin
                    try
                      LFailureLog.Free;
                      LFailureLog := LogToJSONArray(nxmodule.nxQuery1.Log);
                    except
                      // Diagnostic capture must not replace the statement
                      // failure being propagated.
                    end;
                  end;
                  raise;
                end;
              end;
            finally
              LDataArray.Free;
              LDataArray := nil;
              LStatementResult.Free;
              LStatementResult := nil;
            end;
          end);
      end;

      // All statements succeeded, commit
      nxmodule.ExecuteWithoutRetry(
        procedure
        begin
          nxmodule.nxDatabase1.Commit;
        end);
      LTransactionStarted := False;

      // Build success result
      LResultObj.AddPair('success', TJSONBool.Create(True));
      LResultObj.AddPair('transactionCommitted', TJSONBool.Create(True));
      LResultObj.AddPair('statementsExecuted', TJSONNumber.Create(LExecutedCount));
      LResultObj.AddPair('totalRowsAffected', TJSONNumber.Create(LTotalRowsAffected));
      LResultObj.AddPair('results', LResultsArray);
      LResultsArray := nil;

      Result := LResultObj.ToJSON;

    except
      on E: Exception do
      begin
        // Preserve the operation failure: rollback and session recovery are
        // best-effort cleanup and must never replace its message.
        LErrorMessage := E.Message;
        LRollbackConfirmed := False;
        LSessionPoisoned := Tnxmodule.IsTimeoutError(E) or
          Tnxmodule.IsReenteredError(E) or
          Tnxmodule.IsConnectionLostError(E);
        // ExecuteWithoutRetry has already retired/reconnected for any
        // poisoned exception it raised. Do not retire that fresh session a
        // second time below; retain this flag for transaction-state reporting.
        LSessionRetired := LSessionPoisoned;

        // Capture this before rollback/recovery can rebuild the query
        // component. A no-retry action may already have captured it in its
        // recovery callback; retain that earlier snapshot if present.
        if (not Assigned(LFailureLog)) and LHasLog and
          (nxmodule.nxQuery1.Log.Count > 0) then
          try
            LFailureLog := LogToJSONArray(nxmodule.nxQuery1.Log);
          except
            // Preserve the original operation failure.
          end;

        // Rollback on any error
        if LTransactionStarted and nxmodule.nxDatabase1.InTransaction then
        begin
          try
            // Rollback itself is a server round-trip. It must not be replayed,
            // and a timeout/re-entry/lost connection during cleanup must retire
            // the session even when the original statement error was ordinary.
            nxmodule.ExecuteWithoutRetry(
              procedure
              begin
                nxmodule.nxDatabase1.Rollback;
              end);
            LRollbackConfirmed := True;
          except
            on LRollbackError: Exception do
              LSessionRetired := Tnxmodule.IsTimeoutError(LRollbackError) or
                Tnxmodule.IsReenteredError(LRollbackError) or
                Tnxmodule.IsConnectionLostError(LRollbackError);
          end;
        end;

        // Free the results array since we're creating a new error response
        LResultsArray.Free;
        LResultsArray := nil;

        // Build error result
        LResultObj.AddPair('success', TJSONBool.Create(False));
        LResultObj.AddPair('transactionCommitted', TJSONBool.Create(False));
        LResultObj.AddPair('transactionRolledBack',
          TJSONBool.Create(LRollbackConfirmed));
        if not LTransactionAttempted then
          LResultObj.AddPair('transactionState', 'notStarted')
        else if LRollbackConfirmed then
          LResultObj.AddPair('transactionState', 'rolledBack')
        else if LSessionPoisoned or LSessionRetired then
          LResultObj.AddPair('transactionState', 'sessionRetired')
        else
          LResultObj.AddPair('transactionState', 'unknown');
        LResultObj.AddPair('statementsExecutedBeforeError', TJSONNumber.Create(LExecutedCount));
        LResultObj.AddPair('failedAtIndex', TJSONNumber.Create(LExecutedCount));
        LResultObj.AddPair('error', LErrorMessage);

        // Include log output if requested (TnxQuery populates Log even on failure)
        if Assigned(LFailureLog) then
        begin
          LResultObj.AddPair('log', LFailureLog);
          LFailureLog := nil;
        end;

        Result := LResultObj.ToJSON;

      end;
    end;

    // Close is itself a server round-trip. It is best-effort after both a
    // successful commit and an operation failure: a close error must neither
    // replace a confirmed success nor replace the original operation response.
    try
      nxmodule.ExecuteWithoutRetry(
        procedure
        begin
          nxmodule.nxQuery1.Close;
        end);
    except
      on E: Exception do
      begin
        // ExecuteWithoutRetry has already recovered any poisoned close
        // failure. The operation result remains authoritative.
      end;
    end;

  finally
    LStatementsArray.Free;
    LFailureLog.Free;
    LResultObj.Free;
    LResultsArray.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('batch_execute',
    function: IMCPTool
    begin
      Result := TBatchExecuteTool.Create;
    end
  );

end.
