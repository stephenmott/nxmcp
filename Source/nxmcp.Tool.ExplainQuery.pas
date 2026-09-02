unit nxmcp.Tool.ExplainQuery;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the explain_query tool
  /// </summary>
  TExplainQueryParams = class
  private
    FSql: string;
    FVerbose: Boolean;
  public
    [SchemaDescription('SQL SELECT query to analyze')]
    property Sql: string read FSql write FSql;
    [SchemaDescription('Use verbose mode (#V+) for full optimizer internals: all indexes considered, relation analysis, decision process. Default is standard mode (#L+) showing plan summary.')]
    property Verbose: Boolean read FVerbose write FVerbose;
  end;

  /// <summary>
  /// MCP Tool that returns the execution plan for a query.
  /// Uses NexusDB query logging to show how the query will be executed.
  /// </summary>
  TExplainQueryTool = class(TMCPToolBase<TExplainQueryParams>)
  protected
    function ExecuteWithParams(const Params: TExplainQueryParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.StrUtils,
  Data.DB,
  MCPServer.Registration,
  nxmcp.SqlUtils,
  dmnx;

{ TExplainQueryTool }

constructor TExplainQueryTool.Create;
begin
  inherited;
  FName := 'explain_query';
  FTitle := 'Explain Query Plan';
  FDescription := 'Show the execution plan for a single SELECT, INSERT, UPDATE or DELETE. ' +
                  'NexusDB has no EXPLAIN - the optimizer only narrates its decisions while a ' +
                  'statement runs - so a SELECT is analysed in no-processing mode: it is parsed, ' +
                  'bound and optimized, but not one row is read and nothing is executed (the ' +
                  'response reports executed=false). No-processing rejects writes, so ' +
                  'INSERT/UPDATE/DELETE do run - inside a transaction that is ALWAYS rolled back, ' +
                  'so they change nothing (the response reports rolledBack). SELECT ... INTO is a ' +
                  'write too and is handled the same way, but note that only the copied rows are ' +
                  'rolled back - the table it creates is left behind empty, because creating it is ' +
                  'not transactional. DDL is rejected for the same reason. Exactly one statement - ' +
                  'no semicolon-separated batches. ' +
                  'Standard mode (#L+) shows plan summary: index used, join strategy. ' +
                  'Verbose mode (#V+) shows full optimizer internals: all available indexes, ' +
                  'relation analysis, index selection decisions, simplification steps. ' +
                  'You can add #I- to disable index optimization or #S- to disable simplification ' +
                  'to compare different execution plans.';
end;

function TExplainQueryTool.ExecuteWithParams(const Params: TExplainQueryParams): string;
const
  // The engine's own answer to "profile this without running it", and the only
  // one: setting the statement option NO_PROCESSING makes
  // TnxSqlRowBuilder.ReadSources (nxsqlTableExp.pas) return immediately, while
  // Optimize - and with it the whole #L+/#V+ narration - still runs. So a SELECT
  // is parsed, bound and optimized without a single row being read.
  //
  // #OPT::<group>::<name>='<value>' is a statement-prefix switch like #L/#V/#T
  // (nxSQLParse.pas, compPROD_nxSQL loops over all switch kinds in any order), so
  // it composes both with our log switch and with an #I-/#S- the caller supplied.
  // Scope is the statement, not the session: nothing leaks into the next call.
  cNoProcessing = '#OPT::STATEMENT::NO_PROCESSING=''1''';
var
  LResultObj: TJSONObject;
  LPlanArray: TJSONArray;
  LSwitch: string;
  I: Integer;
  LFacts: TnxSqlFacts;
  LNeedsRollback: Boolean;
  LNoProcessing: Boolean;
begin
  // Validate parameters
  if Trim(Params.Sql) = '' then
    raise Exception.Create('SQL query cannot be empty');

  LFacts := AnalyzeSql(Params.Sql);
  if LFacts.Kind = skUnparsable then
    raise Exception.Create('SQL could not be parsed. Check the statement syntax.');
  if not LFacts.IsSingle then
    raise Exception.Create('Only a single statement can be explained - a second statement ' +
      'after a semicolon would also be executed. Use batch_execute to run several statements.');
  if not (LFacts.Kind in [skSelect, skInsert, skUpdate, skDelete]) then
    raise Exception.Create('Only SELECT, INSERT, UPDATE and DELETE can be explained. ' +
      'DDL fits neither strategy: no-processing mode refuses it, and it is not transactional, ' +
      'so running it could not be rolled back afterwards. Use execute_sql to run DDL.');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Choose logging switch: #V+ for verbose, #L+ for standard
  if Params.Verbose then
    LSwitch := '#V+'
  else
    LSwitch := '#L+';

  // NexusDB has no EXPLAIN, and the plan is not an artifact the engine builds -
  // Optimize records its decisions in the row builder's own state and merely
  // narrates them into TnxQuery.Log. That log is written into the ExecStream of
  // StatementExecDirect (nxdb.pas) and never into the prepare stream, so it can
  // only be had by executing. Hence two different strategies:
  //
  //  * reads      - no-processing mode (see cNoProcessing): optimizer runs, row
  //                 loop does not. Nothing is executed, so nothing to undo.
  //  * writes     - no-processing REJECTS them ('UPDATE not supported in no
  //                 processing mode', raised at the top of the statement's
  //                 Execute in nxsqlDataManip.pas), so they really do run, inside
  //                 a transaction that is always rolled back.
  //
  // DDL is rejected above: it is not transactional, so a rollback would not undo
  // it - and no-processing refuses it too.
  //
  // A write is any of the three DML verbs, and also SELECT ... INTO - that reads
  // like a query but creates and populates a table, so it has to be wrapped too.
  LNeedsRollback := (LFacts.Kind in [skInsert, skUpdate, skDelete]) or
                    ((LFacts.Kind = skSelect) and LFacts.HasInto);
  LNoProcessing := not LNeedsRollback;
  if LNoProcessing then
    LSwitch := LSwitch + ' ' + cNoProcessing;

  if LNeedsRollback then
  begin
    // Writes must never be replayed.  ExecuteWithoutRetry still retires a
    // poisoned session, but deliberately makes no second attempt after a
    // transaction or statement round-trip fails.
    try
      nxmodule.ExecuteWithoutRetry(
        procedure
        begin
          nxmodule.nxDatabase1.StartTransaction(False);
          nxmodule.nxQuery1.Close;
          nxmodule.nxQuery1.SQL.Text := LSwitch + ' ' + Params.Sql;
          nxmodule.nxQuery1.Open;
        end);
    except
      on E: Exception do
      begin
        // Never replay a write used for explanation. Preserve the query error
        // even if rollback also fails, then retire a poisoned session.
        if nxmodule.nxDatabase1.InTransaction then
        begin
          try
            nxmodule.ExecuteWithoutRetry(
              procedure
              begin
                nxmodule.nxDatabase1.Rollback;
              end);
          except
            on LRollbackError: Exception do
            begin
              // ExecuteWithoutRetry has already retired any poisoned session.
              // Preserve the original query error.
            end;
          end;
        end;
        // A failure before the normal result/finally path must still close the
        // cursor. Cleanup is best-effort so it cannot replace the statement
        // error being re-raised.
        try
          nxmodule.ExecuteWithoutRetry(
            procedure
            begin
              nxmodule.nxQuery1.Close;
            end);
        except
          on LCloseError: Exception do
          begin
            // Preserve E; ExecuteWithoutRetry already retired poisoned
            // sessions raised by the close.
          end;
        end;
        raise;
      end;
    end;
  end
  else
    // No-processing: nothing is executed and there is no transaction to lose, so
    // a dropped connection can be retried without any risk of repeating work.
    nxmodule.ExecuteWithReconnect(
      procedure
      begin
        nxmodule.nxQuery1.Close;
        nxmodule.nxQuery1.SQL.Text := LSwitch + ' ' + Params.Sql;
        nxmodule.nxQuery1.Open;
      end);

  try
    // Build result from Log property
    LResultObj := TJSONObject.Create;
    LPlanArray := nil;
    try
      LResultObj.AddPair('sql', Params.Sql);
      LResultObj.AddPair('mode', IfThen(Params.Verbose, 'verbose', 'standard'));

      LPlanArray := TJSONArray.Create;
      for I := 0 to nxmodule.nxQuery1.Log.Count - 1 do
        LPlanArray.Add(nxmodule.nxQuery1.Log[I]);

      LResultObj.AddPair('plan', LPlanArray);
      LPlanArray := nil;
      LResultObj.AddPair('lineCount', TJSONNumber.Create(nxmodule.nxQuery1.Log.Count));
      LResultObj.AddPair('executed', TJSONBool.Create(not LNoProcessing));
      LResultObj.AddPair('rolledBack', TJSONBool.Create(LNeedsRollback));

      // Say which of the two strategies produced this plan, so a caller can tell
      // "optimized but never run" from "ran and was undone".
      if LNoProcessing then
        LResultObj.AddPair('note',
          'Analysed in NexusDB no-processing mode: the statement was parsed, bound and ' +
          'optimized to produce this plan, but the row loop never ran - no rows were read ' +
          'and nothing was executed. Row counts the optimizer only learns while reading are ' +
          'therefore absent from the plan.');

      // Be precise rather than reassuring: for SELECT ... INTO the rollback undoes
      // the rows but NOT the table itself, because creating it is not
      // transactional (verified - the target table is left behind, empty).
      if (LFacts.Kind = skSelect) and LFacts.HasInto then
        LResultObj.AddPair('note',
          'The rollback undid the copied rows, but table creation is not transactional ' +
          'in NexusDB: the table named by INTO now exists and is empty. Remove it with ' +
          'drop_table if it was not wanted.');

      Result := LResultObj.ToJSON;
    finally
      LPlanArray.Free;
      LResultObj.Free;
    end;
  finally
    try
      nxmodule.ExecuteWithoutRetry(
        procedure
        begin
          nxmodule.nxQuery1.Close;
        end);
    except
      on E: Exception do
      begin
        // A failing close must not skip rollback. Preserve the close error even
        // when rollback fails. Each cleanup round-trip applies no-retry recovery.
        if LNeedsRollback and nxmodule.nxDatabase1.InTransaction then
          try
            nxmodule.ExecuteWithoutRetry(
              procedure
              begin
                nxmodule.nxDatabase1.Rollback;
              end);
          except
          end;
        raise;
      end;
    end;

    // Always roll back - the statement ran only to produce the plan.
    if LNeedsRollback and nxmodule.nxDatabase1.InTransaction then
    begin
      nxmodule.ExecuteWithoutRetry(
        procedure
        begin
          nxmodule.nxDatabase1.Rollback;
        end);
    end;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('explain_query',
    function: IMCPTool
    begin
      Result := TExplainQueryTool.Create;
    end
  );

end.
