program TestSerializedManager;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Rtti,
  nxdbBase,
  nxllBde,
  nxllException,
  MCPServer.Types,
  nxmcp.CapabilityFilter in '..\..\Source\nxmcp.CapabilityFilter.pas',
  nxmcp.NexusErrors in '..\..\Source\nxmcp.NexusErrors.pas',
  nxmcp.SerializedManager in '..\..\Source\nxmcp.SerializedManager.pas';

type
  TFakeManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    FInvokeMethod: string;
    FEntered: TEvent;
    FRelease: TEvent;
    FBlockInvocations: Boolean;
    FRaiseNext: Boolean;
    FExecuteCount: Integer;
    FInvokeCount: Integer;
    FActiveCount: Integer;
    FMaxActiveCount: Integer;
  public
    constructor Create(const AInvokeMethod: string);
    destructor Destroy; override;
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string;
      const Params: TJSONObject): TValue;
    procedure BlockInvocations;
    procedure ReleaseInvocations;
    procedure ResetEvents;
    property Entered: TEvent read FEntered;
    property ExecuteCount: Integer read FExecuteCount;
    property InvokeCount: Integer read FInvokeCount;
    property MaxActiveCount: Integer read FMaxActiveCount;
    property RaiseNext: Boolean read FRaiseNext write FRaiseNext;
  end;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create('FAILED: ' + AMessage);
end;

function ToolParams(const AName: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', AName);
  Result.AddPair('arguments', TJSONObject.Create);
end;

function ResourceParams(const AURI: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', AURI);
end;

{ TFakeManager }

constructor TFakeManager.Create(const AInvokeMethod: string);
begin
  inherited Create;
  FInvokeMethod := AInvokeMethod;
  FEntered := TEvent.Create(nil, True, False, '');
  FRelease := TEvent.Create(nil, True, True, '');
end;

destructor TFakeManager.Destroy;
begin
  FRelease.Free;
  FEntered.Free;
  inherited;
end;

function TFakeManager.GetCapabilityName: string;
begin
  Result := 'fake';
end;

function TFakeManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := True;
end;

function TFakeManager.ExecuteMethod(const Method: string;
  const Params: TJSONObject): TValue;
var
  LActive: Integer;
begin
  Result := TValue.Empty;
  TInterlocked.Increment(FExecuteCount);
  if not SameText(Method, FInvokeMethod) then
    Exit;

  TInterlocked.Increment(FInvokeCount);
  LActive := TInterlocked.Increment(FActiveCount);
  if LActive > FMaxActiveCount then
    FMaxActiveCount := LActive;
  FEntered.SetEvent;
  try
    if FRaiseNext then
    begin
      FRaiseNext := False;
      raise Exception.Create('synthetic inner failure');
    end;
    if FBlockInvocations then
      FRelease.WaitFor(INFINITE);
  finally
    TInterlocked.Decrement(FActiveCount);
  end;
end;

procedure TFakeManager.BlockInvocations;
begin
  FBlockInvocations := True;
  FRelease.ResetEvent;
end;

procedure TFakeManager.ReleaseInvocations;
begin
  FBlockInvocations := False;
  FRelease.SetEvent;
end;

procedure TFakeManager.ResetEvents;
begin
  FEntered.ResetEvent;
end;

procedure TestSerializationAndDiscovery;
var
  LFakeObject: TFakeManager;
  LFake: IMCPCapabilityManager;
  LGate: INxExecutionGate;
  LManager: IMCPCapabilityManager;
  LThread1: TThread;
  LThread2: TThread;
begin
  LGate := CreateExecutionGate;
  LFakeObject := TFakeManager.Create('tools/call');
  LFake := LFakeObject;
  LManager := SerializeTools(LFake, LGate, 1000);
  LFakeObject.BlockInvocations;

  LThread1 := TThread.CreateAnonymousThread(
    procedure
    var
      LParams: TJSONObject;
    begin
      LParams := ToolParams('first');
      try
        LManager.ExecuteMethod('tools/call', LParams);
      finally
        LParams.Free;
      end;
    end);
  LThread1.FreeOnTerminate := False;
  LThread1.Start;
  Check(LFakeObject.Entered.WaitFor(1000) = wrSignaled,
    'first invocation did not enter');

  // Discovery must bypass the database gate while the first call is blocked.
  LManager.ExecuteMethod('tools/list', nil);

  LFakeObject.ResetEvents;
  LThread2 := TThread.CreateAnonymousThread(
    procedure
    var
      LParams: TJSONObject;
    begin
      LParams := ToolParams('second');
      try
        LManager.ExecuteMethod('tools/call', LParams);
      finally
        LParams.Free;
      end;
    end);
  LThread2.FreeOnTerminate := False;
  LThread2.Start;
  TThread.Sleep(100);
  Check(LFakeObject.InvokeCount = 1,
    'second invocation reached the inner manager concurrently');

  LFakeObject.ReleaseInvocations;
  LThread1.WaitFor;
  LThread2.WaitFor;
  Check(LFakeObject.InvokeCount = 2, 'second invocation never ran');
  Check(LFakeObject.MaxActiveCount = 1, 'inner concurrency exceeded one');
  LThread2.Free;
  LThread1.Free;
end;

procedure TestSharedToolResourceGateAndBusyShape;
var
  LToolObject: TFakeManager;
  LToolFake: IMCPCapabilityManager;
  LResourceObject: TFakeManager;
  LResourceFake: IMCPCapabilityManager;
  LGate: INxExecutionGate;
  LTools: IMCPCapabilityManager;
  LResources: IMCPCapabilityManager;
  LThread: TThread;
  LParams: TJSONObject;
  LResult: TValue;
  LResultObject: TJSONObject;
  LContents: TJSONArray;
  LContent: TJSONObject;
begin
  LGate := CreateExecutionGate;
  LToolObject := TFakeManager.Create('tools/call');
  LToolFake := LToolObject;
  LResourceObject := TFakeManager.Create('resources/read');
  LResourceFake := LResourceObject;
  LTools := SerializeTools(LToolFake, LGate, 50);
  LResources := SerializeResources(LResourceFake, LGate, 50);
  LToolObject.BlockInvocations;

  LThread := TThread.CreateAnonymousThread(
    procedure
    var
      LThreadParams: TJSONObject;
    begin
      LThreadParams := ToolParams('holder');
      try
        LTools.ExecuteMethod('tools/call', LThreadParams);
      finally
        LThreadParams.Free;
      end;
    end);
  LThread.FreeOnTerminate := False;
  LThread.Start;
  Check(LToolObject.Entered.WaitFor(1000) = wrSignaled,
    'tool holder did not enter');

  // Resource discovery methods must remain responsive while the shared gate is held.
  LResources.ExecuteMethod('resources/list', nil);
  LResources.ExecuteMethod('resources/templates/list', nil);
  Check(LResourceObject.ExecuteCount = 2,
    'resource discovery did not bypass the shared gate');

  // A contending tool gets a normal CallToolResult and never reaches its inner manager.
  LParams := ToolParams('contender');
  try
    LResult := LTools.ExecuteMethod('tools/call', LParams);
    Check(LResult.IsType<TJSONObject>, 'busy tool result is not JSON');
    LResultObject := LResult.AsType<TJSONObject>;
    try
      Check(LResultObject.GetValue<Boolean>('isError'),
        'busy tool result does not set isError');
      LContents := LResultObject.GetValue('content') as TJSONArray;
      Check(Assigned(LContents) and (LContents.Count = 1),
        'busy tool result has no content item');
      LContent := LContents.Items[0] as TJSONObject;
      Check(LContent.GetValue<string>('text').StartsWith('Error:'),
        'busy tool text does not begin with Error:');
      Check(LToolObject.InvokeCount = 1,
        'busy tool call reached its inner manager');
    finally
      LResultObject.Free;
    end;
  finally
    LParams.Free;
  end;

  LParams := ResourceParams('nexusdb://schema');
  try
    LResult := LResources.ExecuteMethod('resources/read', LParams);
    Check(LResult.IsType<TJSONObject>, 'busy resource result is not JSON');
    LResultObject := LResult.AsType<TJSONObject>;
    try
      Check(LResultObject.GetValue('contents') is TJSONArray,
        'busy resource result has no contents array');
      LContents := LResultObject.GetValue('contents') as TJSONArray;
      LContent := LContents.Items[0] as TJSONObject;
      Check(LContent.GetValue<string>('uri') = 'nexusdb://schema',
        'busy resource result lost the requested URI');
      Check(LContent.GetValue<string>('text').StartsWith('Error reading resource:'),
        'busy resource result has the wrong error shape');
      Check(LResourceObject.InvokeCount = 0,
        'busy resource call reached its inner manager');
    finally
      LResultObject.Free;
    end;
  finally
    LParams.Free;
  end;

  LToolObject.ReleaseInvocations;
  LThread.WaitFor;
  LThread.Free;
end;

procedure TestCapabilityFilterIsOutermost;
var
  LFakeObject: TFakeManager;
  LFake: IMCPCapabilityManager;
  LGate: INxExecutionGate;
  LSerialized: IMCPCapabilityManager;
  LFiltered: IMCPCapabilityManager;
  LThread: TThread;
  LParams: TJSONObject;
begin
  LGate := CreateExecutionGate;
  LFakeObject := TFakeManager.Create('tools/call');
  LFake := LFakeObject;
  LSerialized := SerializeTools(LFake, LGate, 500);
  LFiltered := FilterTools(LSerialized,
    function(const AName: string): Boolean
    begin
      Result := not SameText(AName, 'disabled');
    end);
  LFakeObject.BlockInvocations;

  LThread := TThread.CreateAnonymousThread(
    procedure
    var
      LThreadParams: TJSONObject;
    begin
      LThreadParams := ToolParams('holder');
      try
        LFiltered.ExecuteMethod('tools/call', LThreadParams);
      finally
        LThreadParams.Free;
      end;
    end);
  LThread.FreeOnTerminate := False;
  LThread.Start;
  Check(LFakeObject.Entered.WaitFor(1000) = wrSignaled,
    'filtered holder did not enter');

  LParams := ToolParams('disabled');
  try
    try
      LFiltered.ExecuteMethod('tools/call', LParams);
      Check(False, 'disabled tool was not rejected');
    except
      on E: Exception do
        Check(E.Message.Contains('disabled in nxmcp.ini'),
          'disabled tool waited on the gate instead of failing in the filter');
    end;
  finally
    LParams.Free;
  end;
  Check(LFakeObject.InvokeCount = 1,
    'disabled tool reached the serialized inner manager');

  LFakeObject.ReleaseInvocations;
  LThread.WaitFor;
  LThread.Free;
end;

procedure TestNexusErrorClassificationAndRetryCleanup;
var
  LDatabaseError: EnxDatabaseError;
  LBaseError: EnxBaseException;
  LAttemptCount: Integer;
  LRecoveryCount: Integer;
  LRecoveryTrace: TStringList;
begin
  LDatabaseError := EnxDatabaseError.nxCreate(DBIERR_REENTERED);
  try
    Check(NexusErrorCode(LDatabaseError) = DBIERR_REENTERED,
      'EnxDatabaseError code was not classified');
    Check(IsReenteredError(LDatabaseError),
      'EnxDatabaseError re-entry was not recognized');
  finally
    LDatabaseError.Free;
  end;

  LBaseError := EnxBaseException.nxCreate(DBIERR_NX_GENERALTIMEOUT);
  try
    Check(NexusErrorCode(LBaseError) = DBIERR_NX_GENERALTIMEOUT,
      'EnxBaseException code was not classified');
    Check(IsTimeoutError(LBaseError),
      'EnxBaseException timeout was not recognized');
  finally
    LBaseError.Free;
  end;

  LAttemptCount := 0;
  LRecoveryCount := 0;
  LRecoveryTrace := TStringList.Create;
  try
    try
      ExecuteNexusPolicy(
        procedure
        begin
          Inc(LAttemptCount);
          if LAttemptCount = 1 then
            raise EnxDatabaseError.nxCreate(DBIERR_SERVERCOMMLOST)
          else
            raise EnxBaseException.nxCreate(DBIERR_NX_GENERALTIMEOUT);
        end,
        True,
        function(E: Exception): Boolean
        begin
          LRecoveryTrace.Add('recover:' + IntToStr(NexusErrorCode(E)));
          Inc(LRecoveryCount);
          Result := True;
        end,
        nil,
        procedure(E: Exception)
        begin
          LRecoveryTrace.Add('before:' + IntToStr(NexusErrorCode(E)));
        end);
      Check(False, 'timeout on the retry did not escape');
    except
      on E: EnxBaseException do
        Check(E.ErrorCode = DBIERR_NX_GENERALTIMEOUT,
          'retry surfaced the wrong original failure');
    end;
    Check(LAttemptCount = 2, 'retry-enabled policy did not make exactly two attempts');
    Check(LRecoveryCount = 2,
      'failure on the second attempt did not run poisoned-session recovery');
    Check(LRecoveryTrace.Count = 4,
      'before-recovery callback did not observe both failures');
    if LRecoveryTrace.Count = 4 then
    begin
      Check(LRecoveryTrace[0] = 'before:' + IntToStr(DBIERR_SERVERCOMMLOST),
        'first before-recovery callback saw the wrong failure');
      Check(LRecoveryTrace[1] = 'recover:' + IntToStr(DBIERR_SERVERCOMMLOST),
        'first recovery did not follow its callback');
      Check(LRecoveryTrace[2] = 'before:' + IntToStr(DBIERR_NX_GENERALTIMEOUT),
        'second before-recovery callback saw the wrong failure');
      Check(LRecoveryTrace[3] = 'recover:' + IntToStr(DBIERR_NX_GENERALTIMEOUT),
        'second recovery did not follow its callback');
    end;
  finally
    LRecoveryTrace.Free;
  end;

  LAttemptCount := 0;
  LRecoveryCount := 0;
  try
    ExecuteNexusPolicy(
      procedure
      begin
        Inc(LAttemptCount);
        raise EnxDatabaseError.nxCreate(DBIERR_SERVERCOMMLOST);
      end,
      False,
      function(E: Exception): Boolean
      begin
        Inc(LRecoveryCount);
        Result := True;
      end);
    Check(False, 'no-retry policy swallowed communication loss');
  except
    on E: EnxDatabaseError do
      Check(E.ErrorCode = DBIERR_SERVERCOMMLOST,
        'no-retry policy surfaced the wrong original failure');
  end;
  Check((LAttemptCount = 1) and (LRecoveryCount = 1),
    'no-retry policy replayed an operation or skipped recovery');
end;

procedure TestExceptionReleasesGate;
var
  LFakeObject: TFakeManager;
  LFake: IMCPCapabilityManager;
  LGate: INxExecutionGate;
  LManager: IMCPCapabilityManager;
  LParams: TJSONObject;
begin
  LGate := CreateExecutionGate;
  LFakeObject := TFakeManager.Create('tools/call');
  LFake := LFakeObject;
  LManager := SerializeTools(LFake, LGate, 100);
  LFakeObject.RaiseNext := True;

  LParams := ToolParams('raises');
  try
    try
      LManager.ExecuteMethod('tools/call', LParams);
      Check(False, 'synthetic failure did not escape');
    except
      on E: Exception do
        Check(E.Message = 'synthetic inner failure',
          'unexpected synthetic failure text');
    end;
  finally
    LParams.Free;
  end;

  LParams := ToolParams('after-failure');
  try
    LManager.ExecuteMethod('tools/call', LParams);
  finally
    LParams.Free;
  end;
  Check(LFakeObject.InvokeCount = 2, 'gate remained locked after exception');
end;

begin
  try
    TestSerializationAndDiscovery;
    TestSharedToolResourceGateAndBusyShape;
    TestCapabilityFilterIsOutermost;
    TestExceptionReleasesGate;
    TestNexusErrorClassificationAndRetryCleanup;
    Writeln('PASS: serialized manager concurrency tests');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
