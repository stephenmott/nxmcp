unit nxmcp.NexusErrors;

interface

uses
  System.SysUtils;

type
  TNxRecoveryFunc = reference to function(E: Exception): Boolean;
  TNxFailureProc = reference to procedure(E: Exception);

function NexusErrorCode(E: Exception): Integer;
function IsConnectionLostError(E: Exception): Boolean;
function IsTimeoutError(E: Exception): Boolean;
function IsReenteredError(E: Exception): Boolean;

/// <summary>
/// Runs one NexusDB operation under the shared retry contract. Recovery is
/// invoked for every poisoned-session failure, including a failure raised by
/// the second attempt. General timeouts are never retried.
/// </summary>
function ExecuteNexusPolicy(const AAction: TProc; AAllowRetry: Boolean;
  const ARecover: TNxRecoveryFunc; const AOnRetry: TProc = nil;
  const ABeforeRecovery: TNxFailureProc = nil): Boolean;

implementation

uses
  nxdbBase,
  nxllBde,
  nxllException;

function NexusErrorCode(E: Exception): Integer;
begin
  if E is EnxDatabaseError then
    Result := EnxDatabaseError(E).ErrorCode
  else if E is EnxBaseException then
    Result := EnxBaseException(E).ErrorCode
  else
    Result := DBIERR_NONE;
end;

function IsConnectionLostError(E: Exception): Boolean;
begin
  Result := NexusErrorCode(E) = DBIERR_SERVERCOMMLOST;
end;

function IsTimeoutError(E: Exception): Boolean;
begin
  // DBIERR_NX_FILTERTIMEOUT is a local filter timeout and does not leave a
  // server request running. Only the general request timeout poisons a session.
  Result := NexusErrorCode(E) = DBIERR_NX_GENERALTIMEOUT;
end;

function IsReenteredError(E: Exception): Boolean;
begin
  Result := NexusErrorCode(E) = DBIERR_REENTERED;
end;

function ExecuteNexusPolicy(const AAction: TProc; AAllowRetry: Boolean;
  const ARecover: TNxRecoveryFunc; const AOnRetry: TProc;
  const ABeforeRecovery: TNxFailureProc): Boolean;
var
  LAttempt: Integer;

  procedure NotifyBeforeRecovery(E: Exception);
  begin
    if not Assigned(ABeforeRecovery) then
      Exit;

    // Diagnostics are best-effort and must never replace the NexusDB exception
    // that determines whether this session has to be retired.
    try
      ABeforeRecovery(E);
    except
      // Preserve the original exception.
    end;
  end;

begin
  LAttempt := 0;
  while True do
  begin
    try
      AAction();
      Exit(True);
    except
      on E: Exception do
      begin
        if IsTimeoutError(E) then
        begin
          NotifyBeforeRecovery(E);
          ARecover(E);
          raise;
        end;

        if IsConnectionLostError(E) or IsReenteredError(E) then
        begin
          NotifyBeforeRecovery(E);
          if not (ARecover(E) and AAllowRetry and (LAttempt = 0)) then
            raise;
        end
        else
          raise;
      end;
    end;

    Inc(LAttempt);
    if Assigned(AOnRetry) then
      AOnRetry();
  end;
end;

end.
