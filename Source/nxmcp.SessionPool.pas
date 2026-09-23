unit nxmcp.SessionPool;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  nxsrServerEngine,
  nxsqlEngine,
  dmnx,
  nxmcp.SerializedManager;

type
  /// <summary>
  /// A fixed set of Tnxmodule contexts - each with its own session, database,
  /// datasets and (in remote mode) its own transport - handed out one per tool
  /// call or resource read by the execution gate, so independent requests run
  /// concurrently instead of queueing behind one session.
  ///
  /// Every context points at the same target. Calls that change the target or
  /// need a table nobody else has open (see IsExclusiveTool) run exclusively:
  /// before one runs, the other contexts release their server-side table cache;
  /// after it, they adopt the acting context's target and timeout.
  ///
  /// The in-process embedded engine is owned here and shared by all contexts.
  /// </summary>
  TnxSessionPool = class
  private
    FModules: TObjectList<Tnxmodule>;
    FEmbeddedEngine: TnxServerEngine;
    FSqlEngine: TnxSqlEngine;
    FGate: INxExecutionGate;
    FLogLock: TObject;
    FLastQueryLog: TArray<string>;
    procedure EnterSlot(ASlot: Integer; AExclusive: Boolean);
    procedure LeaveSlot(ASlot: Integer; AExclusive: Boolean);
    procedure PrepareExclusive(AActing: Tnxmodule);
    procedure SyncAfterExclusive(AActing: Tnxmodule);
    procedure PublishQueryLog(AModule: Tnxmodule);
    function GetPrimary: Tnxmodule;
    function GetSize: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Log lines of the most recent query that produced any.</summary>
    function LastQueryLog: TArray<string>;
    /// <summary>
    /// The first context: holds the ini switches and serves startup logging. Only
    /// read its configuration outside a gated call - its session may be in use.
    /// </summary>
    property Primary: Tnxmodule read GetPrimary;
    property Gate: INxExecutionGate read FGate;
    property Size: Integer read GetSize;
  end;

var
  NexusPool: TnxSessionPool;

implementation

uses
  System.Classes,
  MCPServer.Logger;

threadvar
  // The nxmodule binding in force before the gate bound a pooled context.
  GPreviousModule: Tnxmodule;

{ TnxSessionPool }

constructor TnxSessionPool.Create;
var
  I: Integer;
  LModule: Tnxmodule;
begin
  inherited Create;
  FLogLock := TObject.Create;
  FModules := TObjectList<Tnxmodule>.Create(True);

  // Mirrors the wiring the embedded demos (and formerly dmnx.dfm) declare.
  FSqlEngine := TnxSqlEngine.Create(nil);
  FEmbeddedEngine := TnxServerEngine.Create(nil);
  FEmbeddedEngine.ServerName := '';
  FEmbeddedEngine.Options := [];
  FEmbeddedEngine.TableExtension := 'nx1';
  FEmbeddedEngine.SqlEngine := FSqlEngine;

  LModule := Tnxmodule.Create(nil);
  FModules.Add(LModule);
  LModule.InitializePrimary(FEmbeddedEngine);

  for I := 2 to LModule.PoolSize do
  begin
    LModule := Tnxmodule.Create(nil);
    FModules.Add(LModule);
    LModule.InitializeFrom(Primary, FEmbeddedEngine);
  end;

  FGate := CreateExecutionGate(FModules.Count,
    procedure(ASlot: Integer; AExclusive: Boolean)
    begin
      EnterSlot(ASlot, AExclusive);
    end,
    procedure(ASlot: Integer; AExclusive: Boolean)
    begin
      LeaveSlot(ASlot, AExclusive);
    end);

  TLogger.Info(Format('NexusDB session pool: %d session(s).', [FModules.Count]));
end;

destructor TnxSessionPool.Destroy;
begin
  FGate := nil;
  // Each context disconnects in its OnDestroy; only then can the shared engine,
  // which their sessions point at, be stopped and freed.
  FModules.Free;
  try
    if FEmbeddedEngine.Active then
      FEmbeddedEngine.Active := False;
  except
    on E: Exception do
      TLogger.Warning('Stopping the embedded NexusDB engine failed: ' + E.Message);
  end;
  FEmbeddedEngine.Free;
  FSqlEngine.Free;
  FLogLock.Free;
  inherited;
end;

function TnxSessionPool.GetPrimary: Tnxmodule;
begin
  Result := FModules[0];
end;

function TnxSessionPool.GetSize: Integer;
begin
  Result := FModules.Count;
end;

procedure TnxSessionPool.EnterSlot(ASlot: Integer; AExclusive: Boolean);
var
  LModule: Tnxmodule;
begin
  LModule := FModules[ASlot];
  GPreviousModule := nxmodule;
  nxmodule := LModule;
  // Client-side list; lets LeaveSlot tell whether this call produced a log.
  LModule.nxQuery1.Log.Clear;
  if AExclusive then
    try
      PrepareExclusive(LModule);
    except
      // The gate releases the slot without calling LeaveSlot; undo the binding.
      nxmodule := GPreviousModule;
      GPreviousModule := nil;
      raise;
    end;
end;

procedure TnxSessionPool.LeaveSlot(ASlot: Integer; AExclusive: Boolean);
var
  LModule: Tnxmodule;
begin
  LModule := FModules[ASlot];
  try
    PublishQueryLog(LModule);
    if AExclusive then
      SyncAfterExclusive(LModule);
  finally
    nxmodule := GPreviousModule;
    GPreviousModule := nil;
  end;
end;

procedure TnxSessionPool.PrepareExclusive(AActing: Tnxmodule);
var
  LModule: Tnxmodule;
begin
  // Every other context is idle (the gate guarantees it), so touching their
  // components from this thread is safe.
  for LModule in FModules do
    if LModule <> AActing then
      LModule.ReleaseServerCache;
end;

procedure TnxSessionPool.SyncAfterExclusive(AActing: Tnxmodule);
var
  LModule: Tnxmodule;
begin
  for LModule in FModules do
    if LModule <> AActing then
      LModule.SyncTargetFrom(AActing);

  // All contexts now share the acting context's mode. Once that is remote,
  // nobody has a session on the embedded engine and it can stop, releasing the
  // database folder it had open.
  if not AActing.IsEmbedded and FEmbeddedEngine.Active then
    try
      FEmbeddedEngine.Active := False;
    except
      on E: Exception do
        TLogger.Warning('Stopping the embedded NexusDB engine failed: ' + E.Message);
    end;
end;

procedure TnxSessionPool.PublishQueryLog(AModule: Tnxmodule);
begin
  if AModule.nxQuery1.Log.Count = 0 then
    Exit;
  TMonitor.Enter(FLogLock);
  try
    FLastQueryLog := AModule.nxQuery1.Log.ToStringArray;
  finally
    TMonitor.Exit(FLogLock);
  end;
end;

function TnxSessionPool.LastQueryLog: TArray<string>;
begin
  TMonitor.Enter(FLogLock);
  try
    Result := Copy(FLastQueryLog);
  finally
    TMonitor.Exit(FLogLock);
  end;
end;

end.
