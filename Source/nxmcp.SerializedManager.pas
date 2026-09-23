unit nxmcp.SerializedManager;

interface

uses
  System.JSON,
  MCPServer.Types;

type
  /// <summary>
  /// Called on the invoking thread right after a slot is handed out (OnEnter) or
  /// right before it is returned (OnLeave). AExclusive is True when the call holds
  /// every slot.
  /// </summary>
  TNxSlotEvent = reference to procedure(ASlot: Integer; AExclusive: Boolean);

  /// <summary>
  /// Decides whether a tools/call must run alone (holding every slot) rather than
  /// on one slot next to other calls. AArguments may be nil.
  /// </summary>
  TNxExclusivePredicate = reference to function(const AName: string;
    const AArguments: TJSONObject): Boolean;

  /// <summary>
  /// One execution gate is shared by the tools and resources managers because
  /// both draw on the same pool of NexusDB sessions. A gate has SlotCount slots
  /// (one per pooled session): a shared entry takes one free slot, an exclusive
  /// entry waits until every slot is free and takes them all. A waiting exclusive
  /// entry blocks new shared entries so it cannot be starved.
  /// </summary>
  INxExecutionGate = interface
    ['{5C0B8E61-3F7A-4C1D-9E2B-8A4D6F13C2E7}']
    function TryEnter(const AOperation: string; AExclusive: Boolean;
      ATimeoutMs: Cardinal; out ASlot: Integer;
      out ABlockingOperation: string): Boolean;
    procedure Leave(ASlot: Integer);
    function SlotCount: Integer;
  end;

function CreateExecutionGate(ASlotCount: Integer = 1;
  const AOnEnter: TNxSlotEvent = nil;
  const AOnLeave: TNxSlotEvent = nil): INxExecutionGate;

function SerializeTools(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal;
  const AIsExclusive: TNxExclusivePredicate = nil): IMCPCapabilityManager;

function SerializeResources(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal): IMCPCapabilityManager;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.Rtti,
  System.Diagnostics,
  System.Generics.Collections,
  MCPServer.Logger;

type
  TnxManagerKind = (mkTools, mkResources);

  TnxExecutionGate = class(TInterfacedObject, INxExecutionGate)
  private
    FLock: TObject;
    // Free slots as a stack: the most recently released slot is handed out next,
    // so sequential traffic keeps reusing one (already connected) session and the
    // others are only brought up under real concurrency.
    FIdle: TList<Integer>;
    FActive: TArray<string>;
    FExclusiveHeld: Boolean;
    FExclusiveWaiting: Integer;
    FOnEnter: TNxSlotEvent;
    FOnLeave: TNxSlotEvent;
    function DescribeActive: string;
    function WaitRemaining(const AWatch: TStopwatch; ATimeoutMs: Cardinal): Boolean;
    procedure ReleaseSlot(ASlot: Integer);
  public
    constructor Create(ASlotCount: Integer; const AOnEnter, AOnLeave: TNxSlotEvent);
    destructor Destroy; override;
    function TryEnter(const AOperation: string; AExclusive: Boolean;
      ATimeoutMs: Cardinal; out ASlot: Integer;
      out ABlockingOperation: string): Boolean;
    procedure Leave(ASlot: Integer);
    function SlotCount: Integer;
  end;

  TnxSerializedManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    FInner: IMCPCapabilityManager;
    FGate: INxExecutionGate;
    FBusyTimeoutMs: Cardinal;
    FKind: TnxManagerKind;
    FIsExclusive: TNxExclusivePredicate;
    FInvokeMethod: string;
    FInvokeParamKey: string;
    function SafeOperationValue(const AValue: string): string;
    function InvokedName(const Params: TJSONObject): string;
    function OperationDescription(const Params: TJSONObject): string;
    function WantsExclusive(const Params: TJSONObject): Boolean;
    function BusyMessage(const ABlockingOperation: string;
      AExclusive: Boolean): string;
    function BuildToolBusyResult(const AMessage: string): TValue;
    function BuildResourceBusyResult(const Params: TJSONObject;
      const AMessage: string): TValue;
  public
    constructor Create(const AInner: IMCPCapabilityManager;
      const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal;
      AKind: TnxManagerKind; const AIsExclusive: TNxExclusivePredicate);
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string;
      const Params: TJSONObject): TValue;
  end;

function CreateExecutionGate(ASlotCount: Integer;
  const AOnEnter: TNxSlotEvent; const AOnLeave: TNxSlotEvent): INxExecutionGate;
begin
  Result := TnxExecutionGate.Create(ASlotCount, AOnEnter, AOnLeave);
end;

function SerializeTools(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal;
  const AIsExclusive: TNxExclusivePredicate): IMCPCapabilityManager;
begin
  Result := TnxSerializedManager.Create(AInner, AGate, ABusyTimeoutMs, mkTools,
    AIsExclusive);
end;

function SerializeResources(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal): IMCPCapabilityManager;
begin
  Result := TnxSerializedManager.Create(AInner, AGate, ABusyTimeoutMs,
    mkResources, nil);
end;

{ TnxExecutionGate }

constructor TnxExecutionGate.Create(ASlotCount: Integer;
  const AOnEnter, AOnLeave: TNxSlotEvent);
var
  I: Integer;
begin
  inherited Create;
  if ASlotCount < 1 then
    raise EArgumentOutOfRangeException.Create('ASlotCount');
  FLock := TObject.Create;
  FIdle := TList<Integer>.Create;
  SetLength(FActive, ASlotCount);
  // Push in reverse so slot 0 is on top and is handed out first.
  for I := ASlotCount - 1 downto 0 do
    FIdle.Add(I);
  FOnEnter := AOnEnter;
  FOnLeave := AOnLeave;
end;

destructor TnxExecutionGate.Destroy;
begin
  FIdle.Free;
  FLock.Free;
  inherited;
end;

function TnxExecutionGate.SlotCount: Integer;
begin
  Result := Length(FActive);
end;

function TnxExecutionGate.DescribeActive: string;
var
  LOperation: string;
begin
  // Caller holds FLock.
  Result := '';
  for LOperation in FActive do
    if LOperation <> '' then
    begin
      if Result <> '' then
        Result := Result + '; ';
      Result := Result + LOperation;
    end;
end;

function TnxExecutionGate.WaitRemaining(const AWatch: TStopwatch;
  ATimeoutMs: Cardinal): Boolean;
var
  LElapsed: Int64;
begin
  // Caller holds FLock and re-checks its condition after every wake-up, so a
  // spurious or unrelated pulse is harmless.
  LElapsed := AWatch.ElapsedMilliseconds;
  if LElapsed >= ATimeoutMs then
    Exit(False);
  TMonitor.Wait(FLock, Cardinal(ATimeoutMs - LElapsed));
  Result := True;
end;

function TnxExecutionGate.TryEnter(const AOperation: string;
  AExclusive: Boolean; ATimeoutMs: Cardinal; out ASlot: Integer;
  out ABlockingOperation: string): Boolean;
var
  LWatch: TStopwatch;
begin
  ASlot := -1;
  ABlockingOperation := '';
  LWatch := TStopwatch.StartNew;

  TMonitor.Enter(FLock);
  try
    if AExclusive then
    begin
      Inc(FExclusiveWaiting);
      while FExclusiveHeld or (FIdle.Count < Length(FActive)) do
        if not WaitRemaining(LWatch, ATimeoutMs) then
        begin
          Dec(FExclusiveWaiting);
          // Shared entries may have been held back only by this waiter.
          TMonitor.PulseAll(FLock);
          ABlockingOperation := DescribeActive;
          Exit(False);
        end;
      Dec(FExclusiveWaiting);
      FExclusiveHeld := True;
    end
    else
      while FExclusiveHeld or (FExclusiveWaiting > 0) or (FIdle.Count = 0) do
        if not WaitRemaining(LWatch, ATimeoutMs) then
        begin
          ABlockingOperation := DescribeActive;
          Exit(False);
        end;

    ASlot := FIdle.Last;
    FIdle.Delete(FIdle.Count - 1);
    FActive[ASlot] := AOperation;
    Result := True;
  finally
    TMonitor.Exit(FLock);
  end;

  // Outside the lock: the hook may make server round-trips.
  if Assigned(FOnEnter) then
    try
      FOnEnter(ASlot, AExclusive);
    except
      ReleaseSlot(ASlot);
      raise;
    end;
end;

procedure TnxExecutionGate.Leave(ASlot: Integer);
var
  LExclusive: Boolean;
begin
  TMonitor.Enter(FLock);
  try
    LExclusive := FExclusiveHeld;
  finally
    TMonitor.Exit(FLock);
  end;

  try
    if Assigned(FOnLeave) then
      FOnLeave(ASlot, LExclusive);
  except
    // The slot must come back whatever the hook did, and the tool's own result
    // must not be replaced by a housekeeping failure.
    on E: Exception do
      TLogger.Warning('Releasing NexusDB session slot ' + IntToStr(ASlot) +
        ' failed: ' + E.Message);
  end;
  ReleaseSlot(ASlot);
end;

procedure TnxExecutionGate.ReleaseSlot(ASlot: Integer);
begin
  TMonitor.Enter(FLock);
  try
    FActive[ASlot] := '';
    FIdle.Add(ASlot);
    FExclusiveHeld := False;
    TMonitor.PulseAll(FLock);
  finally
    TMonitor.Exit(FLock);
  end;
end;

{ TnxSerializedManager }

constructor TnxSerializedManager.Create(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal;
  AKind: TnxManagerKind; const AIsExclusive: TNxExclusivePredicate);
begin
  inherited Create;
  if not Assigned(AInner) then
    raise EArgumentNilException.Create('AInner');
  if not Assigned(AGate) then
    raise EArgumentNilException.Create('AGate');

  FInner := AInner;
  FGate := AGate;
  FBusyTimeoutMs := ABusyTimeoutMs;
  FKind := AKind;
  FIsExclusive := AIsExclusive;
  case FKind of
    mkTools:
      begin
        FInvokeMethod := 'tools/call';
        FInvokeParamKey := 'name';
      end;
    mkResources:
      begin
        FInvokeMethod := 'resources/read';
        FInvokeParamKey := 'uri';
      end;
  end;
end;

function TnxSerializedManager.GetCapabilityName: string;
begin
  Result := FInner.GetCapabilityName;
end;

function TnxSerializedManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := FInner.HandlesMethod(Method);
end;

function TnxSerializedManager.InvokedName(const Params: TJSONObject): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if not Assigned(Params) then
    Exit;
  LValue := Params.GetValue(FInvokeParamKey);
  if Assigned(LValue) then
    Result := LValue.Value;
end;

function TnxSerializedManager.OperationDescription(
  const Params: TJSONObject): string;
var
  LSafeValue: string;
begin
  Result := FInvokeMethod;
  LSafeValue := SafeOperationValue(InvokedName(Params));
  if LSafeValue <> '' then
    Result := Result + ' ' + LSafeValue;
end;

function TnxSerializedManager.WantsExclusive(const Params: TJSONObject): Boolean;
var
  LArguments: TJSONObject;
begin
  if (FKind <> mkTools) or not Assigned(FIsExclusive) then
    Exit(False);
  LArguments := nil;
  if Assigned(Params) and (Params.GetValue('arguments') is TJSONObject) then
    LArguments := TJSONObject(Params.GetValue('arguments'));
  Result := FIsExclusive(InvokedName(Params), LArguments);
end;

function TnxSerializedManager.SafeOperationValue(const AValue: string): string;
var
  I: Integer;
begin
  Result := Trim(AValue);
  for I := 1 to Length(Result) do
    if Result[I] < ' ' then
      Result[I] := ' ';
  if Length(Result) > 160 then
    Result := Copy(Result, 1, 157) + '...';
end;

function TnxSerializedManager.BusyMessage(
  const ABlockingOperation: string; AExclusive: Boolean): string;
begin
  if AExclusive then
    Result := Format(
      'NexusDB is busy: this operation needs exclusive use of all %d pooled ' +
      'sessions and other requests were still running after %d ms; no database ' +
      'operation was started. Retry after they complete or increase [Options] ' +
      'BusyTimeout.', [FGate.SlotCount, FBusyTimeoutMs])
  else if FGate.SlotCount > 1 then
    Result := Format(
      'NexusDB is busy: all %d pooled sessions were still in use after %d ms; ' +
      'no database operation was started. Retry after a request completes, or ' +
      'increase [Options] BusyTimeout or [Options] PoolSize.',
      [FGate.SlotCount, FBusyTimeoutMs])
  else
    Result := Format(
      'NexusDB is busy processing another request; no database operation was started ' +
      'after waiting %d ms. Retry after it completes or increase [Options] BusyTimeout.',
      [FBusyTimeoutMs]);
  if ABlockingOperation <> '' then
    Result := Result + ' Active operations: ' + ABlockingOperation + '.';
end;

function TnxSerializedManager.BuildToolBusyResult(
  const AMessage: string): TValue;
var
  LContent: TJSONArray;
  LItem: TJSONObject;
  LResult: TJSONObject;
begin
  LResult := TJSONObject.Create;
  LContent := TJSONArray.Create;
  LResult.AddPair('content', LContent);
  LItem := TJSONObject.Create;
  LContent.AddElement(LItem);
  LItem.AddPair('type', 'text');
  LItem.AddPair('text', 'Error: ' + AMessage);
  LResult.AddPair('isError', TJSONBool.Create(True));
  Result := TValue.From<TJSONObject>(LResult);
end;

function TnxSerializedManager.BuildResourceBusyResult(const Params: TJSONObject;
  const AMessage: string): TValue;
var
  LContent: TJSONObject;
  LContents: TJSONArray;
  LResult: TJSONObject;
  LURI: string;
  LValue: TJSONValue;
begin
  LURI := '';
  if Assigned(Params) then
  begin
    LValue := Params.GetValue('uri');
    if Assigned(LValue) then
      LURI := LValue.Value;
  end;

  LResult := TJSONObject.Create;
  LContents := TJSONArray.Create;
  LResult.AddPair('contents', LContents);
  LContent := TJSONObject.Create;
  LContents.AddElement(LContent);
  LContent.AddPair('uri', LURI);
  LContent.AddPair('mimeType', 'text/plain');
  LContent.AddPair('text', 'Error reading resource: ' + AMessage);
  Result := TValue.From<TJSONObject>(LResult);
end;

function TnxSerializedManager.ExecuteMethod(const Method: string;
  const Params: TJSONObject): TValue;
var
  LBlockingOperation: string;
  LExclusive: Boolean;
  LMessage: string;
  LOperation: string;
  LSlot: Integer;
  LStopwatch: TStopwatch;
begin
  if not SameText(Method, FInvokeMethod) then
    Exit(FInner.ExecuteMethod(Method, Params));

  LOperation := OperationDescription(Params);
  LExclusive := WantsExclusive(Params);
  LStopwatch := TStopwatch.StartNew;
  if not FGate.TryEnter(LOperation, LExclusive, FBusyTimeoutMs, LSlot,
    LBlockingOperation) then
  begin
    LStopwatch.Stop;
    LMessage := BusyMessage(LBlockingOperation, LExclusive);
    TLogger.Warning(Format('%s (actual wait %d ms)',
      [LMessage, LStopwatch.ElapsedMilliseconds]));
    if FKind = mkTools then
      Exit(BuildToolBusyResult(LMessage))
    else
      Exit(BuildResourceBusyResult(Params, LMessage));
  end;

  LStopwatch.Stop;
  if LStopwatch.ElapsedMilliseconds > 0 then
    TLogger.Info(Format('Acquired NexusDB session %d%s for %s after %d ms.',
      [LSlot, IfThen(LExclusive, ' (exclusive)', ''), LOperation,
       LStopwatch.ElapsedMilliseconds]));
  try
    Result := FInner.ExecuteMethod(Method, Params);
  finally
    FGate.Leave(LSlot);
  end;
end;

end.
