unit nxmcp.SerializedAccess;

{ All MCP tools and resources operate on the single shared NexusDB
  session/database/datasets owned by Tnxmodule (dmnx). A NexusDB session is
  strictly one-request-at-a-time: a second request arriving while the session's
  server-side lock is held is not queued but rejected - TnxSimpleLock.Lock
  raises DBIERR_REENTERED ("System has been illegally re-entered") inside the
  server. The MCP HTTP transport (TIdHTTPServer) handles every request on its
  own Indy thread, so overlapping tool calls WOULD hit the session concurrently
  unless serialized.

  These base classes are drop-in replacements for TMCPToolBase<T> /
  TMCPResourceBase<T> that funnel tool execution and resource reads through one
  process-wide gate. The base Execute/Read are not virtual, so the gate
  re-implements the interface to rebind its slot to the wrapping method - a
  tool must derive from these classes (not the MCPServer ones) to be covered.
  Under the STDIO transport requests are already sequential; the gate is then
  uncontended and effectively free. }

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Resource.Base;

type
  // Non-generic front for the gate: methods of a generic class cannot reference
  // implementation-section symbols (E2506), so the generic bases below go
  // through this class while the critical section itself stays private to the
  // unit.
  TNxGate = class
  public
    class procedure Enter; static;
    class procedure Leave; static;
  end;

  TSerializedToolBase<T: class, constructor> = class(TMCPToolBase<T>, IMCPTool)
  public
    // Hides the non-virtual TMCPToolBase<T>.Execute; re-listing IMCPTool above
    // rebinds the interface method to this implementation.
    function Execute(const Arguments: TJSONObject): TValue;
  end;

  TSerializedResourceBase<T: class, constructor> = class(TMCPResourceBase<T>, IMCPResource)
  public
    function Read: string;
  end;

implementation

uses
  System.SyncObjs;

var
  // One gate for the whole process: there is exactly one NexusDB session, so
  // finer-grained locking has nothing to win.
  GNxGate: TCriticalSection;

{ TNxGate }

class procedure TNxGate.Enter;
begin
  GNxGate.Enter;
end;

class procedure TNxGate.Leave;
begin
  GNxGate.Leave;
end;

{ TSerializedToolBase<T> }

function TSerializedToolBase<T>.Execute(const Arguments: TJSONObject): TValue;
begin
  TNxGate.Enter;
  try
    Result := inherited Execute(Arguments);
  finally
    TNxGate.Leave;
  end;
end;

{ TSerializedResourceBase<T> }

function TSerializedResourceBase<T>.Read: string;
begin
  TNxGate.Enter;
  try
    Result := inherited Read;
  finally
    TNxGate.Leave;
  end;
end;

initialization
  GNxGate := TCriticalSection.Create;

finalization
  GNxGate.Free;

end.
