unit nxmcp.FileLog;

{
  Process-local file logging for nxmcp.

  This deliberately does NOT use TLogger's own LogToFile. TLogger opens the log
  via TStreamWriter.Create(FileName, ...), which passes no share bits and so
  takes an exclusive handle, and it lets an open failure escape as an exception.
  Under the STDIO transport every MCP client spawns its own nxmcp.exe (Claude
  Code alongside Claude Desktop), so the second instance to start could not open
  the shared log and died before its transport ever came up - which the client
  sees as "MCP server exited immediately".

  Instead we keep TLogger.LogToFile off and hook TLogger.OnLogMessage, writing
  the file ourselves with:
    - a per-process default name, <exe name>.<pid>.log,
    - fmShareDenyWrite, so editors and tail can read the log while we hold it,
    - fail-soft behaviour: any I/O error disables file logging and warns on
      stderr, but never propagates into the server.

  TLogger calls OnLogMessage from inside its own lock, so the callback is
  already serialised; it hands us the fully formatted line (timestamp, level)
  and has already applied MinLogLevel filtering.
}

interface

/// <summary>
/// Default per-process log file: &lt;exe name&gt;.&lt;pid&gt;.log next to the executable.
/// </summary>
function DefaultLogFileName: string;

/// <summary>
/// Open AFileName for append and route TLogger output to it. Returns False (and
/// warns on stderr) if the file cannot be opened; the caller may ignore that,
/// logging simply stays console-only.
/// </summary>
function EnableFileLog(const AFileName: string): Boolean;

/// <summary>
/// Detach from TLogger and close the log file. Safe to call when not enabled.
/// </summary>
procedure DisableFileLog;

implementation

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  MCPServer.Logger;

var
  GLogStream: TFileStream = nil;
  GHooked: Boolean = False;

function DefaultLogFileName: string;
begin
  Result := ChangeFileExt(ParamStr(0), Format('.%u.log', [GetCurrentProcessId]));
end;

/// Report a logging failure without going through TLogger: we are called from
/// inside its DoWriteLog, and stdout carries JSON-RPC under the STDIO transport.
procedure WarnToStdErr(const AMessage: string);
begin
  try
    WriteLn(ErrOutput, Format('[%s] [WARN ] %s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), AMessage]));
  except
    // no usable stderr - nothing further we can do
  end;
end;

procedure CloseLogStream;
begin
  FreeAndNil(GLogStream);
end;

procedure WriteLogLine(const ALine: string);
var
  LBytes: TBytes;
begin
  if not Assigned(GLogStream) then
    Exit;
  try
    LBytes := TEncoding.UTF8.GetBytes(ALine + sLineBreak);
    GLogStream.WriteBuffer(LBytes, Length(LBytes));
  except
    on E: Exception do
    begin
      // Disk full, file deleted under us, ... - drop to console-only rather
      // than let the exception unwind into whatever was being logged.
      CloseLogStream;
      WarnToStdErr(Format('File logging disabled, write failed: %s', [E.Message]));
    end;
  end;
end;

function EnableFileLog(const AFileName: string): Boolean;
var
  LIsNew: Boolean;
  LMode: Word;
  LPreamble: TBytes;
begin
  DisableFileLog;

  try
    LIsNew := not FileExists(AFileName);
    if LIsNew then
      LMode := fmCreate or fmShareDenyWrite
    else
      LMode := fmOpenWrite or fmShareDenyWrite;

    GLogStream := TFileStream.Create(AFileName, LMode);
    GLogStream.Seek(0, soEnd);

    if LIsNew then
    begin
      LPreamble := TEncoding.UTF8.GetPreamble;
      GLogStream.WriteBuffer(LPreamble, Length(LPreamble));
    end;
  except
    on E: Exception do
    begin
      CloseLogStream;
      WarnToStdErr(Format('File logging disabled, cannot open "%s": %s',
        [AFileName, E.Message]));
      Exit(False);
    end;
  end;

  TLogger.OnLogMessage :=
    procedure(const AMessage: string)
    begin
      WriteLogLine(AMessage);
    end;
  GHooked := True;
  Result := True;
end;

procedure DisableFileLog;
begin
  if GHooked then
  begin
    TLogger.OnLogMessage := nil;
    GHooked := False;
  end;
  CloseLogStream;
end;

initialization

finalization
  // Runs before MCPServer.Logger's finalization (we use that unit), so TLogger
  // is still alive here and safe to detach from.
  DisableFileLog;

end.
