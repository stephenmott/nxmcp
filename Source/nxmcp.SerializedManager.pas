unit nxmcp.SerializedManager;

interface

uses
  System.JSON,
  MCPServer.Types;

type
  /// <summary>
  /// One execution gate is shared by the tools and resources managers because
  /// both ultimately use the same NexusDB session and datasets.
  /// </summary>
  INxExecutionGate = interface
    ['{77DDA7FC-977D-4D47-A033-AEA03D307952}']
    function TryEnter(const AOperation: string; ATimeoutMs: Cardinal;
      out ABlockingOperation: string): Boolean;
    procedure Leave;
  end;

function CreateExecutionGate: INxExecutionGate;

function SerializeTools(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal): IMCPCapabilityManager;

function SerializeResources(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal): IMCPCapabilityManager;

implementation

uses
  System.SysUtils,
  System.Rtti,
  System.Diagnostics,
  MCPServer.Logger;

type
  TnxManagerKind = (mkTools, mkResources);

  TnxExecutionGate = class(TInterfacedObject, INxExecutionGate)
  private
    FLock: TObject;
    FStateLock: TObject;
    FActiveOperation: string;
    function GetActiveOperation: string;
  public
    constructor Create;
    destructor Destroy; override;
    function TryEnter(const AOperation: string; ATimeoutMs: Cardinal;
      out ABlockingOperation: string): Boolean;
    procedure Leave;
  end;

  TnxSerializedManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    FInner: IMCPCapabilityManager;
    FGate: INxExecutionGate;
    FBusyTimeoutMs: Cardinal;
    FKind: TnxManagerKind;
    FInvokeMethod: string;
    FInvokeParamKey: string;
    function SafeOperationValue(const AValue: string): string;
    function OperationDescription(const Params: TJSONObject): string;
    function BusyMessage(const ABlockingOperation: string): string;
    function BuildToolBusyResult(const AMessage: string): TValue;
    function BuildResourceBusyResult(const Params: TJSONObject;
      const AMessage: string): TValue;
  public
    constructor Create(const AInner: IMCPCapabilityManager;
      const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal;
      AKind: TnxManagerKind);
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string;
      const Params: TJSONObject): TValue;
  end;

function CreateExecutionGate: INxExecutionGate;
begin
  Result := TnxExecutionGate.Create;
end;

function SerializeTools(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal): IMCPCapabilityManager;
begin
  Result := TnxSerializedManager.Create(AInner, AGate, ABusyTimeoutMs, mkTools);
end;

function SerializeResources(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal): IMCPCapabilityManager;
begin
  Result := TnxSerializedManager.Create(AInner, AGate, ABusyTimeoutMs, mkResources);
end;

{ TnxExecutionGate }

constructor TnxExecutionGate.Create;
begin
  inherited Create;
  FLock := TObject.Create;
  FStateLock := TObject.Create;
end;

destructor TnxExecutionGate.Destroy;
begin
  FStateLock.Free;
  FLock.Free;
  inherited;
end;

function TnxExecutionGate.GetActiveOperation: string;
begin
  TMonitor.Enter(FStateLock);
  try
    Result := FActiveOperation;
  finally
    TMonitor.Exit(FStateLock);
  end;
end;

function TnxExecutionGate.TryEnter(const AOperation: string;
  ATimeoutMs: Cardinal; out ABlockingOperation: string): Boolean;
begin
  Result := TMonitor.Enter(FLock, ATimeoutMs);
  if not Result then
  begin
    ABlockingOperation := GetActiveOperation;
    Exit;
  end;

  TMonitor.Enter(FStateLock);
  try
    FActiveOperation := AOperation;
  finally
    TMonitor.Exit(FStateLock);
  end;
  ABlockingOperation := '';
end;

procedure TnxExecutionGate.Leave;
begin
  TMonitor.Enter(FStateLock);
  try
    FActiveOperation := '';
  finally
    TMonitor.Exit(FStateLock);
  end;
  TMonitor.Exit(FLock);
end;

{ TnxSerializedManager }

constructor TnxSerializedManager.Create(const AInner: IMCPCapabilityManager;
  const AGate: INxExecutionGate; ABusyTimeoutMs: Cardinal;
  AKind: TnxManagerKind);
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

function TnxSerializedManager.OperationDescription(
  const Params: TJSONObject): string;
var
  LValue: TJSONValue;
  LSafeValue: string;
begin
  Result := FInvokeMethod;
  if not Assigned(Params) then
    Exit;
  LValue := Params.GetValue(FInvokeParamKey);
  if Assigned(LValue) then
  begin
    LSafeValue := SafeOperationValue(LValue.Value);
    if LSafeValue <> '' then
      Result := Result + ' ' + LSafeValue;
  end;
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
  const ABlockingOperation: string): string;
begin
  Result := Format(
    'NexusDB is busy processing another request; no database operation was started ' +
    'after waiting %d ms. Retry after it completes or increase [Options] BusyTimeout.',
    [FBusyTimeoutMs]);
  if ABlockingOperation <> '' then
    Result := Result + ' Active operation: ' + ABlockingOperation + '.';
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
  LMessage: string;
  LOperation: string;
  LStopwatch: TStopwatch;
begin
  if not SameText(Method, FInvokeMethod) then
    Exit(FInner.ExecuteMethod(Method, Params));

  LOperation := OperationDescription(Params);
  LStopwatch := TStopwatch.StartNew;
  if not FGate.TryEnter(LOperation, FBusyTimeoutMs, LBlockingOperation) then
  begin
    LStopwatch.Stop;
    LMessage := BusyMessage(LBlockingOperation);
    TLogger.Warning(Format('%s (actual wait %d ms)',
      [LMessage, LStopwatch.ElapsedMilliseconds]));
    if FKind = mkTools then
      Exit(BuildToolBusyResult(LMessage))
    else
      Exit(BuildResourceBusyResult(Params, LMessage));
  end;

  LStopwatch.Stop;
  if LStopwatch.ElapsedMilliseconds > 0 then
    TLogger.Info(Format('Acquired NexusDB execution gate for %s after %d ms.',
      [LOperation, LStopwatch.ElapsedMilliseconds]));
  try
    Result := FInner.ExecuteMethod(Method, Params);
  finally
    FGate.Leave;
  end;
end;

end.
