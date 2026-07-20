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
  LTotalRowsAffected := 0;
  LExecutedCount := 0;
  LTransactionStarted := False;

  // Determine if logging is requested. Set before the try so the except handler
  // (which runs even if StartTransaction itself fails) never reads it uninitialized.
  LHasLog := Params.VerboseLog or Params.Log;

  try
    try
      // Start transaction
      nxmodule.nxDatabase1.StartTransaction(Params.Snapshot);
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

        nxmodule.nxQuery1.Close;
        nxmodule.nxQuery1.SQL.Text := LSql;

        // Record result for this statement
        LStatementResult := TJSONObject.Create;
        LStatementResult.AddPair('index', TJSONNumber.Create(I));
        LStatementResult.AddPair('statement', Copy(LSqlUpper, 1, Pos(' ', LSqlUpper + ' ') - 1));

        if LIsSelect then
        begin
          // SELECT: Open and return data
          nxmodule.nxQuery1.Open;
          try
            LDataArray := nxmodule.nxQuery1.ToJSONArray;
            LStatementResult.AddPair('rowCount', TJSONNumber.Create(nxmodule.nxQuery1.RecordCount));
            LStatementResult.AddPair('data', LDataArray);

            // Include log output if requested
            if LHasLog then
              LStatementResult.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));
          finally
            nxmodule.nxQuery1.Close;
          end;
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
        Inc(LExecutedCount);
      end;

      // All statements succeeded, commit
      nxmodule.nxDatabase1.Commit;
      LTransactionStarted := False;

      // Build success result
      LResultObj.AddPair('success', TJSONBool.Create(True));
      LResultObj.AddPair('transactionCommitted', TJSONBool.Create(True));
      LResultObj.AddPair('statementsExecuted', TJSONNumber.Create(LExecutedCount));
      LResultObj.AddPair('totalRowsAffected', TJSONNumber.Create(LTotalRowsAffected));
      LResultObj.AddPair('results', LResultsArray);

      Result := LResultObj.ToJSON;

    except
      on E: Exception do
      begin
        // Rollback on any error
        if LTransactionStarted and nxmodule.nxDatabase1.InTransaction then
        begin
          try
            nxmodule.nxDatabase1.Rollback;
          except
            // Ignore rollback errors
          end;
        end;

        // Free the results array since we're creating a new error response
        LResultsArray.Free;

        // Build error result
        LResultObj.AddPair('success', TJSONBool.Create(False));
        LResultObj.AddPair('transactionCommitted', TJSONBool.Create(False));
        LResultObj.AddPair('transactionRolledBack', TJSONBool.Create(True));
        LResultObj.AddPair('statementsExecutedBeforeError', TJSONNumber.Create(LExecutedCount));
        LResultObj.AddPair('failedAtIndex', TJSONNumber.Create(LExecutedCount));
        LResultObj.AddPair('error', E.Message);

        // Include log output if requested (TnxQuery populates Log even on failure)
        if LHasLog and (nxmodule.nxQuery1.Log.Count > 0) then
          LResultObj.AddPair('log', LogToJSONArray(nxmodule.nxQuery1.Log));

        Result := LResultObj.ToJSON;
      end;
    end;

  finally
    LStatementsArray.Free;
    LResultObj.Free;
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
