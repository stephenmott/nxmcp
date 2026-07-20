unit dmnx;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles,
  nxsdServerEngine, nxreRemoteServerEngine, nxdb, Data.DB, nxllComponent,
  nxllTransport, nxptBasePooledTransport, nxthHttpTransport, nxtwWinsockTransport,
  System.JSON, DataSet.Serialize, DataSet.Serialize.Config, System.Generics.Collections,
  nxdbBase, nxllBde, nxsrServerEngine, nxsrSqlEngineBase, nxsqlEngine;

type
  /// <summary>
  /// How the session reaches a NexusDB server:
  ///  smRemote   - via nxRemoteServerEngine1 + transport (a separate NXserver process)
  ///  smEmbedded - via nxServerEngine1, an in-process local server engine (AliasPath only)
  /// </summary>
  TnxServerMode = (smRemote, smEmbedded);

  Tnxmodule = class(TDataModule)
    nxDatabase1: TnxDatabase;
    nxSession1: TnxSession;
    nxTable1: TnxTable;
    nxQuery1: TnxQuery;
    nxRemoteServerEngine1: TnxRemoteServerEngine;
    nxWinsockTransport1: TnxWinsockTransport;
    dsTable1: TDataSource;
    dsQuery1: TDataSource;
    nxServerEngine1: TnxServerEngine;
    nxSqlEngine1: TnxSqlEngine;
    procedure DataModuleCreate(Sender: TObject);
    procedure DataModuleDestroy(Sender: TObject);
  private
    FServerMode: TnxServerMode;
    FDefaultServerMode: TnxServerMode;
    FServerHost: string;
    FServerPort: Integer;
    FAliasName: string;
    FAliasPath: string;
    FDefaultAliasName: string;
    FDefaultAliasPath: string;
    FDefaultServerHost: string;
    FDefaultServerPort: Integer;
    FTablePassword: string;
    FTablePasswordIsCommaList: Boolean;
    FExtraTablePasswords: TArray<string>;
    FUsername: string;
    FPassword: string;
    FAutoConnect: Boolean;
    FTimeout: Integer;
    FLogToFile: Boolean;
    FLogFileName: string;
    FConfigPath: string;
    procedure LoadConfig;
    procedure CreateDefaultConfig;
    procedure ConfigureComponents;
    procedure ConfigureSerializer;
    procedure ConfigureLogging;
    procedure AddSessionPassword(const APassword: string);
    procedure ApplyPassword(const APassword: string; AIsCommaList: Boolean);
    procedure ApplyConfiguredPasswords;
    procedure WireServerEngine;
    function ConnectRemote: Boolean;
    function ConnectEmbedded: Boolean;
    function GetIsEmbedded: Boolean;
    function SwitchDatabaseTarget(const AAliasName, AAliasPath,
      ATablePassword: string): Boolean;
    function AliasDescription: string;
    procedure TearDownComponents(out AFirstError: string);
    procedure ReleaseDatasets;
    procedure CloseDatabaseForSwitch;
    procedure DisconnectForSwitch;
    function OpenTargetDatabase: Boolean;
  public
    function Connect: Boolean;
    procedure Disconnect;
    procedure ForceDisconnect;
    function Reconnect: Boolean;
    function EnsureConnection: Boolean;
    function EnsureSession: Boolean;
    function ExecuteWithReconnect(const AAction: TProc): Boolean;
    function IsConnected: Boolean;
    class function IsConnectionLostError(E: Exception): Boolean; static;
    function GetLastError: string;
    function GetConfigPath: string;
    function GetAliasNames: TStringList;
    function SwitchDatabase(const AAliasName: string;
      const ATablePassword: string = ''): Boolean;
    function SwitchDatabaseByPath(const AAliasPath: string;
      const ATablePassword: string = ''): Boolean;
    function SwitchServer(const AServerHost: string; AServerPort: Integer;
      const AAliasName: string = ''; const ATablePassword: string = '';
      const AAliasPath: string = ''): Boolean;
    function SwitchToEmbedded(const AAliasPath: string;
      const ATablePassword: string = ''): Boolean;
    class function ModeToStr(AMode: TnxServerMode): string; static;
    class function StrToMode(const AValue: string; ADefault: TnxServerMode): TnxServerMode; static;
    property ServerMode: TnxServerMode read FServerMode;
    property DefaultServerMode: TnxServerMode read FDefaultServerMode;
    property IsEmbedded: Boolean read GetIsEmbedded;
    property ServerHost: string read FServerHost;
    property ServerPort: Integer read FServerPort;
    property AliasName: string read FAliasName;
    property AliasPath: string read FAliasPath;
    property DefaultAliasName: string read FDefaultAliasName;
    property DefaultAliasPath: string read FDefaultAliasPath;
    property DefaultServerHost: string read FDefaultServerHost;
    property DefaultServerPort: Integer read FDefaultServerPort;
    property TablePassword: string read FTablePassword;
  end;

var
  nxmodule: Tnxmodule;

implementation

uses
  // nxseAllEngines registers the pluggable storage/index/record sub-engines that a
  // local (embedded) TnxServerEngine needs to open tables. Required for embedded mode.
  nxseAllEngines,
  // nxllException exposes _FatalException: once the engine hits a critical error
  // (e.g. an access violation inside engine code) this process-wide flag is set,
  // every engine call fails with rsFatalError, and nothing resets it short of a
  // process restart. We surface that state in our error messages.
  nxllException,
  nxmcp.FileLog,
  MCPServer.Logger;

{%CLASSGROUP 'System.Classes.TPersistent'}

{$R *.dfm}

var
  GLastError: string;

/// <summary>
/// Append a restart hint when the in-process engine is in the unrecoverable
/// fatal state. The library's own rsFatalError text says "until the server is
/// restarted", which for embedded mode means this very process - spell that out
/// so an MCP client (or the AI driving it) knows reconnecting cannot help.
/// </summary>
function WithFatalHint(const AMessage: string): string;
const
  cHint = ' [the in-process NexusDB engine reported a fatal error and is ' +
          'suspended; nxmcp.exe must be restarted to recover]';
begin
  Result := AMessage;
  if _FatalException and (Pos(cHint, Result) = 0) then
    Result := Result + cHint;
end;

procedure Tnxmodule.DataModuleCreate(Sender: TObject);
begin
  GLastError := '';
  LoadConfig;
  ConfigureLogging;
  ConfigureSerializer;
  ConfigureComponents;

  if FAutoConnect then
    Connect;
end;

procedure Tnxmodule.DataModuleDestroy(Sender: TObject);
begin
  Disconnect;
end;

procedure Tnxmodule.LoadConfig;
var
  LIniFile: TMemIniFile;
  LIndex: Integer;
  LKey: string;
begin
  // Default values
  FServerMode := smRemote;
  FServerHost := 'localhost';
  FServerPort := 16000;
  FAliasName := '';
  FAliasPath := '';
  FTablePassword := '';
  FTablePasswordIsCommaList := True;
  FExtraTablePasswords := nil;
  FUsername := 'Administrator';
  FPassword := 'NexusDB';
  FAutoConnect := True;
  FTimeout := 3000;
  FLogToFile := False;
  FLogFileName := '';

  // Unified config file path
  FConfigPath := ChangeFileExt(ParamStr(0), '.ini');

  // Auto-create config file if it doesn't exist
  if not FileExists(FConfigPath) then
    CreateDefaultConfig;

  LIniFile := TMemIniFile.Create(FConfigPath);
  try
    // Connection section
    FServerMode := StrToMode(LIniFile.ReadString('Connection', 'Mode',
      ModeToStr(FServerMode)), FServerMode);
    FDefaultServerMode := FServerMode;
    FServerHost := LIniFile.ReadString('Connection', 'ServerHost', FServerHost);
    FServerPort := LIniFile.ReadInteger('Connection', 'ServerPort', FServerPort);
    FDefaultServerHost := FServerHost;
    FDefaultServerPort := FServerPort;

    // Database section.
    // AliasName and AliasPath are mutually exclusive on TnxDatabase (setting one
    // clears the other). A configured AliasPath takes precedence over AliasName.
    FAliasName := Trim(LIniFile.ReadString('Database', 'AliasName', FAliasName));
    FAliasPath := Trim(LIniFile.ReadString('Database', 'AliasPath', FAliasPath));
    if FAliasPath <> '' then
      FAliasName := '';
    // Embedded mode has no server-side aliases; only AliasPath is valid there.
    if FServerMode = smEmbedded then
      FAliasName := '';
    FDefaultAliasName := FAliasName;
    FDefaultAliasPath := FAliasPath;
    FTablePassword := LIniFile.ReadString('Database', 'TablePassword', FTablePassword);

    // TablePasswords1, TablePasswords2, ... - one password per key, taken verbatim
    // (unlike TablePassword, not comma-split), for passwords that contain a literal comma.
    LIndex := 1;
    LKey := 'TablePasswords' + IntToStr(LIndex);
    while LIniFile.ValueExists('Database', LKey) do
    begin
      FExtraTablePasswords := FExtraTablePasswords + [LIniFile.ReadString('Database', LKey, '')];
      Inc(LIndex);
      LKey := 'TablePasswords' + IntToStr(LIndex);
    end;

    // Authentication section
    FUsername := LIniFile.ReadString('Authentication', 'Username', FUsername);
    FPassword := LIniFile.ReadString('Authentication', 'Password', FPassword);

    // Options section
    FAutoConnect := LIniFile.ReadBool('Options', 'AutoConnect', FAutoConnect);
    FTimeout := LIniFile.ReadInteger('Options', 'Timeout', FTimeout);
    FLogToFile := LIniFile.ReadBool('Options', 'LogToFile', FLogToFile);
    FLogFileName := LIniFile.ReadString('Options', 'LogFileName', FLogFileName);
  finally
    LIniFile.Free;
  end;
end;

procedure Tnxmodule.CreateDefaultConfig;
var
  LIniFile: TMemIniFile;
begin
  LIniFile := TMemIniFile.Create(FConfigPath);
  try
    // Header comment
    LIniFile.WriteString('Connection', '; nxmcp - NexusDB MCP Server Configuration', '');

    // Connection section
    LIniFile.WriteString('Connection', '; Server mode: Remote (connect to an NXserver) or Embedded (in-process local server)', '');
    LIniFile.WriteString('Connection', '; In Embedded mode only [Database] AliasPath is used (no AliasName), and it must be set.', '');
    LIniFile.WriteString('Connection', 'Mode', 'Remote');
    LIniFile.WriteString('Connection', '; NXserver host address (Remote mode only)', '');
    LIniFile.WriteString('Connection', 'ServerHost', 'localhost');
    LIniFile.WriteString('Connection', '; NXserver port (default: 16000, Remote mode only)', '');
    LIniFile.WriteInteger('Connection', 'ServerPort', 16000);

    // Database section
    LIniFile.WriteString('Database', '; Set EITHER AliasName OR AliasPath (they are mutually exclusive).', '');
    LIniFile.WriteString('Database', '; If both are set, AliasPath takes precedence.', '');
    LIniFile.WriteString('Database', '; Database alias as configured on the NXserver', '');
    LIniFile.WriteString('Database', 'AliasName', 'YourAlias');
    LIniFile.WriteString('Database', '; Server-side filesystem path to the database folder (leave empty to use AliasName)', '');
    LIniFile.WriteString('Database', 'AliasPath', '');
    LIniFile.WriteString('Database', '; Table passwords, comma separated (leave empty if not used)', '');
    LIniFile.WriteString('Database', 'TablePassword', '');
    LIniFile.WriteString('Database', '; For a password that contains a literal comma, add it as TablePasswords1, TablePasswords2, ... instead', '');

    // Authentication section
    LIniFile.WriteString('Authentication', '; NexusDB username', '');
    LIniFile.WriteString('Authentication', 'Username', 'your_username');
    LIniFile.WriteString('Authentication', '; NexusDB password', '');
    LIniFile.WriteString('Authentication', 'Password', 'your_password');

    // Options section
    LIniFile.WriteString('Options', '; Automatically connect on startup (1=yes, 0=no)', '');
    LIniFile.WriteBool('Options', 'AutoConnect', True);
    LIniFile.WriteString('Options', '; Connection timeout in milliseconds', '');
    LIniFile.WriteInteger('Options', 'Timeout', 3000);
    LIniFile.WriteString('Options', '; Write log output to a file (1=yes, 0=no)', '');
    LIniFile.WriteBool('Options', 'LogToFile', False);
    LIniFile.WriteString('Options', '; Log file path (leave empty for <exe name>.<pid>.log next to the executable)', '');
    LIniFile.WriteString('Options', 'LogFileName', '');

    // MCP Server section
    LIniFile.WriteString('Server', '; MCP server configuration', '');
    LIniFile.WriteInteger('Server', 'Port', 3000);
    LIniFile.WriteString('Server', 'Host', 'localhost');
    LIniFile.WriteString('Server', 'Name', 'nxmcp');
    LIniFile.WriteString('Server', 'Version', '4.0.0.0');
    LIniFile.WriteString('Server', 'Endpoint', '/mcp');
    LIniFile.WriteString('Server', '; Transport: http (network server, default) or stdio (for stdio MCP clients like Claude Code)', '');
    LIniFile.WriteString('Server', '; Overridden by the --stdio / --http command-line flags when present', '');
    LIniFile.WriteString('Server', 'Transport', 'http');

    // CORS section
    LIniFile.WriteString('CORS', '; Cross-Origin Resource Sharing configuration', '');
    LIniFile.WriteBool('CORS', 'Enabled', True);
    LIniFile.WriteString('CORS', '; Comma-separated list of allowed origins', '');
    LIniFile.WriteString('CORS', 'AllowedOrigins', 'http://localhost,http://127.0.0.1,https://localhost,https://127.0.0.1');

    // SSL section
    LIniFile.WriteString('SSL', '; SSL/TLS configuration (optional)', '');
    LIniFile.WriteBool('SSL', 'Enabled', False);
    LIniFile.WriteString('SSL', 'CertFile', '');
    LIniFile.WriteString('SSL', 'KeyFile', '');
    LIniFile.WriteString('SSL', 'RootCertFile', '');

    LIniFile.UpdateFile;
  finally
    LIniFile.Free;
  end;
end;

function Tnxmodule.GetConfigPath: string;
begin
  Result := FConfigPath;
end;

class function Tnxmodule.ModeToStr(AMode: TnxServerMode): string;
begin
  if AMode = smEmbedded then
    Result := 'Embedded'
  else
    Result := 'Remote';
end;

class function Tnxmodule.StrToMode(const AValue: string;
  ADefault: TnxServerMode): TnxServerMode;
var
  L: string;
begin
  L := LowerCase(Trim(AValue));
  if (L = 'embedded') or (L = 'local') then
    Result := smEmbedded
  else if L = 'remote' then
    Result := smRemote
  else
    Result := ADefault;
end;

function Tnxmodule.GetIsEmbedded: Boolean;
begin
  Result := FServerMode = smEmbedded;
end;

procedure Tnxmodule.WireServerEngine;
var
  LDesired: TnxBaseServerEngine;
begin
  // Point the session at the engine for the current mode. The ServerEngine setter
  // requires the session to be inactive, so callers must close it first; assigning
  // only when it differs avoids the inactive check on a no-op.
  if FServerMode = smEmbedded then
    LDesired := nxServerEngine1
  else
    LDesired := nxRemoteServerEngine1;
  if nxSession1.ServerEngine <> LDesired then
    nxSession1.ServerEngine := LDesired;
end;

procedure Tnxmodule.ConfigureComponents;
begin
  // Note: the local engine's SQL support is wired declaratively in the DFM
  // (nxServerEngine1.SqlEngine = nxSqlEngine1), matching the NexusDB embedded demos.

  // Configure transport (used by remote mode only)
  nxWinsockTransport1.ServerName := FServerHost;
  nxWinsockTransport1.Port := FServerPort;

  // Configure session
  nxSession1.UserName := FUsername;
  nxSession1.Password := FPassword;

  // Point the session at the engine for the configured mode.
  WireServerEngine;

  // Configure database target. AliasName and AliasPath are mutually exclusive;
  // embedded mode only supports AliasPath (there are no aliases in embedded mode).
  if (FServerMode = smEmbedded) or (FAliasPath <> '') then
    nxDatabase1.AliasPath := FAliasPath
  else
    nxDatabase1.AliasName := FAliasName;
  nxDatabase1.Timeout := FTimeout;
end;

procedure Tnxmodule.ConfigureSerializer;
begin
  // Configure dataset.serialize for JSON compatibility
  with TDataSetSerializeConfig.GetInstance do
  begin
    // ISO 8601 date/time formats
    Export.FormatDate := 'yyyy-mm-dd';
    Export.FormatTime := 'hh:nn:ss';
    Export.FormatDateTime := 'yyyy-mm-dd"T"hh:nn:ss';

    // Include null values in JSON output
    Export.ExportNullValues := True;
    Export.ExportEmptyDataSet := True;

    // Use lowercase field names for JSON
    CaseNameDefinition := TCaseNameDefinition.cndLowerCamelCase;

    // Import settings
    DateInputIsUTC := False;
  end;
end;

procedure Tnxmodule.ConfigureLogging;
var
  LFileName: string;
begin
  // File logging is opt-in via [Options] in the .ini (default off), and is
  // written by nxmcp.FileLog rather than by TLogger: TLogger takes an exclusive
  // handle on the log and treats an open failure as fatal, which kills a second
  // concurrent nxmcp.exe before its transport starts. Leave TLogger.LogToFile
  // off so it never touches a file.
  TLogger.LogToFile := False;

  if not FLogToFile then
  begin
    DisableFileLog;
    Exit;
  end;

  // An empty LogFileName yields <exe name>.<pid>.log: under the STDIO transport
  // every MCP client spawns its own nxmcp.exe, and several run concurrently.
  LFileName := FLogFileName;
  if LFileName = '' then
    LFileName := DefaultLogFileName;

  // A failure here is not fatal - EnableFileLog warns on stderr and logging
  // stays console-only.
  EnableFileLog(LFileName);
end;

procedure Tnxmodule.AddSessionPassword(const APassword: string);
begin
  if APassword <> '' then
    // Native session call: no SQL string literal involved, so no escaping is needed.
    // Used exactly as given - no trimming, since a real password may have significant
    // leading/trailing whitespace.
    nxSession1.PasswordAdd(APassword);
end;

procedure Tnxmodule.ApplyPassword(const APassword: string; AIsCommaList: Boolean);
var
  LRawPassword: string;
begin
  if APassword = '' then
    Exit;

  if AIsCommaList then
  begin
    // Legacy TablePassword INI format: comma-separated list of passwords in one string.
    // Whitespace around each item is incidental formatting, so it is trimmed here only.
    for LRawPassword in APassword.Split([',']) do
      AddSessionPassword(Trim(LRawPassword));
  end
  else
    // Runtime-supplied password (tool call, or persisted from one): a single atomic value,
    // never split on comma, since a real password may legitimately contain one.
    AddSessionPassword(APassword);
end;

procedure Tnxmodule.ApplyConfiguredPasswords;
var
  LExtraPassword: string;
begin
  // Table passwords are session-scoped (PasswordAdd is a session call), so every
  // path that brings up a fresh session has to re-add the whole configured set:
  // the legacy comma-list TablePassword plus each verbatim TablePasswords1..N.
  // Both connect paths (remote and embedded) share this.
  ApplyPassword(FTablePassword, FTablePasswordIsCommaList);
  for LExtraPassword in FExtraTablePasswords do
    AddSessionPassword(LExtraPassword);
end;

function Tnxmodule.Connect: Boolean;
begin
  GLastError := '';

  try
    // Ensure the session is attached to the engine for the current mode. This
    // requires the session to be inactive, which it is on every Connect path
    // (startup, or after ForceDisconnect in Reconnect / the switch methods).
    WireServerEngine;

    if FServerMode = smEmbedded then
      Result := ConnectEmbedded
    else
      Result := ConnectRemote;
  except
    on E: Exception do
    begin
      GLastError := WithFatalHint(E.Message);
      Result := False;
    end;
  end;
end;

function Tnxmodule.ConnectRemote: Boolean;
begin
  // Remote mode uses the transport + remote engine; the embedded engine stays off.
  if nxServerEngine1.Active then
    nxServerEngine1.Active := False;
  if nxSqlEngine1.Active then
    nxSqlEngine1.Active := False;

  // Activate transport
  if not nxWinsockTransport1.Active then
    nxWinsockTransport1.Active := True;

  // Activate remote server engine
  if not nxRemoteServerEngine1.Active then
    nxRemoteServerEngine1.Active := True;

  // Open session
  if not nxSession1.Active then
    nxSession1.Open;

  // Open database
  if not nxDatabase1.Connected then
    nxDatabase1.Open;

  // Set table password(s) if configured
  if nxDatabase1.Connected then
    ApplyConfiguredPasswords;

  Result := nxDatabase1.Connected;
end;

function Tnxmodule.ConnectEmbedded: Boolean;
begin
  // Embedded mode has no aliases; a direct AliasPath to a database folder is required.
  if Trim(FAliasPath) = '' then
    raise Exception.Create(
      'Embedded mode requires an AliasPath (there are no aliases in embedded mode)');

  // The embedded engine opens a directory in this process, so validate the path
  // client-side before touching any component state. This also guards startup
  // with a bad ini path and the switch rollback paths, which reuse Connect.
  if not DirectoryExists(FAliasPath) then
    raise Exception.Create('Embedded database path does not exist: ' + FAliasPath);

  // Embedded mode uses the in-process engine; the remote transport/engine stay off.
  if nxRemoteServerEngine1.Active then
    nxRemoteServerEngine1.Active := False;
  if nxWinsockTransport1.Active then
    nxWinsockTransport1.Active := False;

  // The SQL engine is wired to the local engine in the DFM (SqlEngine = nxSqlEngine1).
  // Open the session. The NexusDB state model makes the SQL engine the state-parent
  // of the server engine, which is the state-parent of the session, so opening the
  // session cascades activation up the chain in the correct order.
  if not nxSession1.Active then
    nxSession1.Open;

  // Point the database at the folder and open it
  if not nxDatabase1.Connected then
  begin
    nxDatabase1.AliasPath := FAliasPath;
    nxDatabase1.Open;
  end;

  // Set table password(s) if configured
  if nxDatabase1.Connected then
    ApplyConfiguredPasswords;

  Result := nxDatabase1.Connected;
end;

procedure Tnxmodule.TearDownComponents(out AFirstError: string);

  procedure Step(const AWhat: string; const AAction: TProc);
  begin
    try
      AAction();
    except
      on E: Exception do
        if AFirstError = '' then
          AFirstError := AWhat + ': ' + E.Message;
    end;
  end;

begin
  // Close in reverse order, each step guarded on its own. Closing a dataset, a
  // database or a session is a server round-trip that raises once the socket is
  // dead, and a single failure must not leave the engines or the transport
  // behind - so every step is attempted and every component ends up inactive.
  // Both engines are torn down, so the components not in use for the current
  // mode are always left inactive. The first error is reported to the caller.
  AFirstError := '';

  Step('nxQuery1',
    procedure begin if nxQuery1.Active then nxQuery1.Close; end);
  Step('nxTable1',
    procedure begin if nxTable1.Active then nxTable1.Close; end);
  Step('nxDatabase1',
    procedure begin if nxDatabase1.Connected then nxDatabase1.Close; end);
  Step('nxSession1',
    procedure begin if nxSession1.Active then nxSession1.Close; end);
  Step('nxRemoteServerEngine1',
    procedure begin if nxRemoteServerEngine1.Active then nxRemoteServerEngine1.Active := False; end);
  Step('nxServerEngine1',
    procedure begin if nxServerEngine1.Active then nxServerEngine1.Active := False; end);
  Step('nxSqlEngine1',
    procedure begin if nxSqlEngine1.Active then nxSqlEngine1.Active := False; end);
  Step('nxWinsockTransport1',
    procedure begin if nxWinsockTransport1.Active then nxWinsockTransport1.Active := False; end);
end;

procedure Tnxmodule.Disconnect;
var
  LError: string;
begin
  // Graceful teardown: completes in full, and reports the first failure.
  TearDownComponents(LError);
  if LError <> '' then
    GLastError := LError;
end;

function Tnxmodule.IsConnected: Boolean;
begin
  Result := nxDatabase1.Connected;
end;

class function Tnxmodule.IsConnectionLostError(E: Exception): Boolean;
begin
  Result := (E is EnxDatabaseError) and
            (EnxDatabaseError(E).ErrorCode = DBIERR_SERVERCOMMLOST);
end;

procedure Tnxmodule.ForceDisconnect;
var
  LError: string;
begin
  // Same teardown as Disconnect, but the error is discarded rather than recorded:
  // callers use this to clear a half-broken state before reconnecting, where the
  // reason the old connection would not close cleanly is of no interest.
  TearDownComponents(LError);
end;

function Tnxmodule.AliasDescription: string;
begin
  // Human-readable label for the active database target (name or server-side path).
  if FAliasPath <> '' then
    Result := 'path ' + FAliasPath
  else
    Result := FAliasName;
end;

function Tnxmodule.Reconnect: Boolean;
begin
  TLogger.Info('Reconnecting to NexusDB...');
  ForceDisconnect;
  Result := Connect;
  if Result then
  begin
    if FServerMode = smEmbedded then
      TLogger.Info('Reconnected to NexusDB (embedded): ' + AliasDescription)
    else
      TLogger.Info('Reconnected to NexusDB: ' + AliasDescription +
                   ' on ' + FServerHost + ':' + IntToStr(FServerPort));
  end
  else
    TLogger.Warning('Reconnect to NexusDB failed: ' + GLastError);
end;

function Tnxmodule.EnsureConnection: Boolean;
begin
  if IsConnected then
    Exit(True);
  Result := Reconnect;
end;

function Tnxmodule.EnsureSession: Boolean;
begin
  GLastError := '';

  if nxSession1.Active then
    Exit(True);

  // Server-level callers (list_aliases, switch_database) need a live session but
  // not an open database - the current database may be exactly what they are
  // trying to get away from. Bring the chain up only as far as the session so a
  // database that will not open cannot block them. Contrast EnsureConnection,
  // which goes all the way to nxDatabase1.Open.
  TLogger.Info('NexusDB session is inactive; re-establishing session...');
  ForceDisconnect;
  try
    WireServerEngine;

    if FServerMode = smRemote then
    begin
      nxWinsockTransport1.Active := True;
      nxRemoteServerEngine1.Active := True;
    end;
    // Embedded mode needs no explicit engine activation: opening the session
    // cascades up through the server engine and the SQL engine (ConnectEmbedded).

    nxSession1.Open;
    Result := nxSession1.Active;
  except
    on E: Exception do
    begin
      GLastError := WithFatalHint(E.Message);
      TLogger.Warning('Failed to re-establish NexusDB session: ' + GLastError);
      Result := False;
    end;
  end;
end;

procedure Tnxmodule.ReleaseDatasets;
begin
  if nxQuery1.Active then
    nxQuery1.Close;
  if nxTable1.Active then
    nxTable1.Close;
  nxSession1.CloseInactiveTables;
end;

procedure Tnxmodule.CloseDatabaseForSwitch;
begin
  // Every step here talks to the server, and the connection may already be dead -
  // that is often *why* the caller is switching. A failed graceful close must
  // never abort the switch, so fall back to ForceDisconnect, which tears the
  // whole chain down without raising. OpenTargetDatabase then rebuilds it.
  try
    ReleaseDatasets;
    if nxDatabase1.Connected then
      nxDatabase1.Close;
  except
    on E: Exception do
    begin
      TLogger.Warning('Graceful database close failed (' + E.Message +
                      '); forcing disconnect.');
      ForceDisconnect;
    end;
  end;
end;

procedure Tnxmodule.DisconnectForSwitch;
begin
  // ReleaseDatasets makes server round-trips (CloseInactiveTables) and raises on a
  // dead connection - which is frequently why the caller is switching in the first
  // place. Disconnect is guarded step by step and always completes, so it needs no
  // fallback of its own.
  try
    ReleaseDatasets;
  except
    on E: Exception do
      TLogger.Warning('Releasing cached tables failed (' + E.Message +
                      '); continuing with disconnect.');
  end;

  Disconnect;
end;

function Tnxmodule.OpenTargetDatabase: Boolean;
begin
  // Callers must already have pointed nxDatabase1 at the new target. A plain
  // database switch keeps the session; if the preceding close degenerated into a
  // ForceDisconnect (dead socket) it did not, and the whole chain has to come
  // back up - Connect reads FAliasName/FAliasPath and reapplies the password.
  if not nxSession1.Active then
    Exit(Connect);

  try
    if not nxDatabase1.Connected then
      nxDatabase1.Open;

    // The session survives a plain database switch, so the TablePasswords1..N
    // extras added at connect time are still registered on it - only the
    // (possibly just-changed) primary password needs reapplying here. The
    // session-was-dropped path above exits via Connect, which re-adds all of them.
    if nxDatabase1.Connected then
      ApplyPassword(FTablePassword, FTablePasswordIsCommaList);

    Result := nxDatabase1.Connected;
  except
    on E: Exception do
    begin
      // nxSession1.Active is a client-side flag: a session whose socket died
      // still reports Active, and only the first round-trip reveals it. Rebuild
      // the connection and try the new target once more.
      if not IsConnectionLostError(E) then
        raise;
      TLogger.Warning('Lost communication opening ' + AliasDescription +
                      '; rebuilding the connection.');
      ForceDisconnect;
      Result := Connect;
    end;
  end;
end;

function Tnxmodule.ExecuteWithReconnect(const AAction: TProc): Boolean;
begin
  try
    AAction();
    Result := True;
  except
    on E: Exception do
    begin
      if IsConnectionLostError(E) then
      begin
        TLogger.Warning('Lost communication with NexusDB during operation; attempting reconnect.');
        if Reconnect then
        begin
          // Retry once. Any exception from the second attempt bubbles up to caller.
          AAction();
          Result := True;
        end
        else
          raise;
      end
      else
        raise;
    end;
  end;
end;

function Tnxmodule.GetLastError: string;
begin
  Result := GLastError;
end;

function Tnxmodule.GetAliasNames: TStringList;
begin
  Result := TStringList.Create;
  try
    // Session must be active to list aliases (database does not need to be connected)
    if not nxSession1.Active then
      raise Exception.Create('Session is not active. Cannot list aliases.');

    nxSession1.GetAliasNames(Result);
  except
    on E: Exception do
    begin
      Result.Free;
      raise;
    end;
  end;
end;

function Tnxmodule.SwitchDatabaseTarget(const AAliasName, AAliasPath,
  ATablePassword: string): Boolean;
var
  LOldAlias: string;
  LOldPath: string;
  LOldPassword: string;
  LOldPasswordIsCommaList: Boolean;
  LTargetDesc: string;
  LFailure: string;
begin
  GLastError := '';

  // Exactly one of AAliasName / AAliasPath must be supplied (they are mutually
  // exclusive on TnxDatabase). Public callers already enforce this; guard anyway.
  if (Trim(AAliasName) = '') and (Trim(AAliasPath) = '') then
  begin
    GLastError := 'Either an alias name or an alias path must be specified';
    raise Exception.Create(GLastError);
  end;
  if (Trim(AAliasName) <> '') and (Trim(AAliasPath) <> '') then
  begin
    GLastError := 'Specify either an alias name or an alias path, not both';
    raise Exception.Create(GLastError);
  end;

  // In embedded mode the alias path is a directory local to this process, so a
  // bad target can be rejected before anything is closed - the current
  // connection stays fully intact. (In remote mode the path is server-side and
  // only the server can judge it.)
  if (FServerMode = smEmbedded) and (AAliasPath <> '') and
     not DirectoryExists(AAliasPath) then
  begin
    GLastError := 'Embedded database path does not exist: ' + AAliasPath;
    raise Exception.Create(GLastError);
  end;

  if AAliasPath <> '' then
    LTargetDesc := 'path "' + AAliasPath + '"'
  else
    LTargetDesc := 'alias "' + AAliasName + '"';

  // Save current state for rollback
  LOldAlias := FAliasName;
  LOldPath := FAliasPath;
  LOldPassword := FTablePassword;
  LOldPasswordIsCommaList := FTablePasswordIsCommaList;

  try
    // Release datasets and close the database. Degrades to a ForceDisconnect if
    // the old connection is already dead; OpenTargetDatabase rebuilds the chain.
    CloseDatabaseForSwitch;

    // Switch to the new target. Assigning one property clears the other on the
    // component, so mirror that in our own tracking fields.
    if AAliasPath <> '' then
    begin
      nxDatabase1.AliasPath := AAliasPath;
      FAliasPath := nxDatabase1.AliasPath;  // component may normalize the path
      FAliasName := '';
    end
    else
    begin
      nxDatabase1.AliasName := AAliasName;
      FAliasName := AAliasName;
      FAliasPath := '';
    end;
    // A tool-supplied password is a single atomic value, never split on comma,
    // since a real password may legitimately contain one.
    FTablePassword := ATablePassword;
    FTablePasswordIsCommaList := False;

    // Reopen on the new target (reapplies the table password)
    if not OpenTargetDatabase then
      raise Exception.Create(GLastError);

    Result := nxDatabase1.Connected;
  except
    on E: Exception do
    begin
      // Held in a local: the rollback below runs Connect, which overwrites GLastError.
      LFailure := 'Failed to switch to ' + LTargetDesc + ': ' + E.Message;

      // Attempt to rollback to the previous target (name or path)
      try
        FAliasName := LOldAlias;
        FAliasPath := LOldPath;
        FTablePassword := LOldPassword;
        FTablePasswordIsCommaList := LOldPasswordIsCommaList;
        if LOldPath <> '' then
          nxDatabase1.AliasPath := LOldPath
        else
          nxDatabase1.AliasName := LOldAlias;

        // OpenTargetDatabase reapplies the restored password using the restored
        // comma-list flag, so a rolled-back legacy TablePassword is split again.
        if not OpenTargetDatabase then
          raise Exception.Create(GLastError);
      except
        on E2: Exception do
          LFailure := LFailure + ' Rollback also failed: ' + E2.Message;
      end;

      GLastError := WithFatalHint(LFailure);
      raise Exception.Create(GLastError);
    end;
  end;
end;

function Tnxmodule.SwitchDatabase(const AAliasName: string;
  const ATablePassword: string): Boolean;
begin
  if FServerMode = smEmbedded then
  begin
    GLastError := 'Alias names are not available in embedded mode; use an alias path instead';
    raise Exception.Create(GLastError);
  end;
  if Trim(AAliasName) = '' then
  begin
    GLastError := 'Alias name cannot be empty';
    raise Exception.Create(GLastError);
  end;
  Result := SwitchDatabaseTarget(AAliasName, '', ATablePassword);
end;

function Tnxmodule.SwitchDatabaseByPath(const AAliasPath: string;
  const ATablePassword: string): Boolean;
begin
  if Trim(AAliasPath) = '' then
  begin
    GLastError := 'Alias path cannot be empty';
    raise Exception.Create(GLastError);
  end;
  Result := SwitchDatabaseTarget('', AAliasPath, ATablePassword);
end;

function Tnxmodule.SwitchServer(const AServerHost: string; AServerPort: Integer;
  const AAliasName: string; const ATablePassword: string;
  const AAliasPath: string): Boolean;
var
  LOldMode: TnxServerMode;
  LOldHost: string;
  LOldPort: Integer;
  LOldAlias: string;
  LOldPath: string;
  LOldPassword: string;
  LOldPasswordIsCommaList: Boolean;
  LOldExtraPasswords: TArray<string>;
  LFailure: string;
begin
  GLastError := '';

  if Trim(AServerHost) = '' then
  begin
    GLastError := 'Server host cannot be empty';
    raise Exception.Create(GLastError);
  end;

  // Use current port if not specified
  if AServerPort <= 0 then
    AServerPort := FServerPort;

  if (Trim(AAliasName) <> '') and (Trim(AAliasPath) <> '') then
  begin
    GLastError := 'Specify either an alias name or an alias path, not both';
    raise Exception.Create(GLastError);
  end;

  // Save current state for rollback
  LOldMode := FServerMode;
  LOldHost := FServerHost;
  LOldPort := FServerPort;
  LOldAlias := FAliasName;
  LOldPath := FAliasPath;
  LOldPassword := FTablePassword;
  LOldPasswordIsCommaList := FTablePasswordIsCommaList;
  LOldExtraPasswords := FExtraTablePasswords;

  try
    // Full teardown (database -> session -> engines -> transport). Never call
    // EnsureConnection here: the server being switched away from is frequently
    // the one that is down, and a teardown failure must not abort the switch.
    DisconnectForSwitch;

    // switch_server always targets a remote NXserver (switching from embedded if needed)
    FServerMode := smRemote;

    // Update server connection properties
    FServerHost := AServerHost;
    FServerPort := AServerPort;
    nxWinsockTransport1.ServerName := AServerHost;
    nxWinsockTransport1.Port := AServerPort;

    // Update the database target if provided (name and path are mutually
    // exclusive; a provided path wins). If neither is given, keep the current
    // target — Disconnect leaves AliasName/AliasPath untouched.
    if AAliasPath <> '' then
    begin
      nxDatabase1.AliasPath := AAliasPath;
      FAliasPath := nxDatabase1.AliasPath;
      FAliasName := '';
    end
    else if AAliasName <> '' then
    begin
      nxDatabase1.AliasName := AAliasName;
      FAliasName := AAliasName;
      FAliasPath := '';
    end;

    // Update table password. A tool-supplied password is a single atomic value, never split
    // on comma. The locally-configured extra passwords are not carried over to a different
    // server unless explicitly supplied here, same as the legacy TablePassword above.
    FTablePassword := ATablePassword;
    FTablePasswordIsCommaList := False;
    FExtraTablePasswords := nil;

    // Full reconnect (transport -> engine -> session -> database + password)
    if not Connect then
      raise Exception.Create(GLastError);

    Result := nxDatabase1.Connected;
  except
    on E: Exception do
    begin
      // Held in a local: the rollback below runs Connect, which overwrites GLastError.
      LFailure := 'Failed to switch to server "' + AServerHost + ':' +
                  IntToStr(AServerPort) + '": ' + E.Message;

      // Attempt to rollback to previous server
      try
        FServerMode := LOldMode;
        FServerHost := LOldHost;
        FServerPort := LOldPort;
        FAliasName := LOldAlias;
        FAliasPath := LOldPath;
        FTablePassword := LOldPassword;
        FTablePasswordIsCommaList := LOldPasswordIsCommaList;
        FExtraTablePasswords := LOldExtraPasswords;
        nxWinsockTransport1.ServerName := LOldHost;
        nxWinsockTransport1.Port := LOldPort;
        if LOldPath <> '' then
          nxDatabase1.AliasPath := LOldPath
        else
          nxDatabase1.AliasName := LOldAlias;

        // Connect reports failure by returning False, not by raising.
        if not Reconnect then
          LFailure := LFailure + ' Rollback also failed: ' + GLastError;
      except
        on E2: Exception do
          LFailure := LFailure + ' Rollback also failed: ' + E2.Message;
      end;

      GLastError := WithFatalHint(LFailure);
      raise Exception.Create(GLastError);
    end;
  end;
end;

function Tnxmodule.SwitchToEmbedded(const AAliasPath: string;
  const ATablePassword: string): Boolean;
var
  LOldMode: TnxServerMode;
  LOldHost: string;
  LOldPort: Integer;
  LOldAlias: string;
  LOldPath: string;
  LOldPassword: string;
  LOldPasswordIsCommaList: Boolean;
  LOldExtraPasswords: TArray<string>;
  LFailure: string;
begin
  GLastError := '';

  if Trim(AAliasPath) = '' then
  begin
    GLastError := 'Embedded mode requires an alias path';
    raise Exception.Create(GLastError);
  end;

  // The embedded engine opens a directory in this process: a bad target can be
  // rejected up front, before anything is torn down, leaving the current
  // connection untouched (no rollback needed).
  if not DirectoryExists(AAliasPath) then
  begin
    GLastError := 'Embedded database path does not exist: ' + AAliasPath;
    raise Exception.Create(GLastError);
  end;

  // Already embedded: only the database target changes, so switch at the
  // database level and keep the engine and session up. A full engine bounce is
  // reserved for actual mode changes - deactivating and reactivating the
  // in-process engine is a far bigger hammer, and older engine builds have
  // crashed doing it, wedging the whole process (see CLAUDE.md).
  if FServerMode = smEmbedded then
  begin
    Result := SwitchDatabaseTarget('', AAliasPath, ATablePassword);
    Exit;
  end;

  // Save current state for rollback
  LOldMode := FServerMode;
  LOldHost := FServerHost;
  LOldPort := FServerPort;
  LOldAlias := FAliasName;
  LOldPath := FAliasPath;
  LOldPassword := FTablePassword;
  LOldPasswordIsCommaList := FTablePasswordIsCommaList;
  LOldExtraPasswords := FExtraTablePasswords;

  try
    // Full teardown (also deactivates the remote transport/engine). Tolerates a
    // dead remote server: switching to embedded is a valid way to escape one.
    DisconnectForSwitch;

    // Switch to the in-process engine with a direct database folder path.
    // A tool-supplied password is a single atomic value, never split on comma.
    // The locally-configured extra passwords are not carried over to a different
    // server unless explicitly supplied here, same as switch_server.
    FServerMode := smEmbedded;
    FTablePassword := ATablePassword;
    FTablePasswordIsCommaList := False;
    FExtraTablePasswords := nil;
    nxDatabase1.AliasPath := AAliasPath;
    FAliasPath := nxDatabase1.AliasPath;  // component may normalize the path
    FAliasName := '';

    // Reconnect via the embedded engine
    if not Connect then
      raise Exception.Create(GLastError);

    Result := nxDatabase1.Connected;
  except
    on E: Exception do
    begin
      // Held in a local: the rollback below runs Connect, which overwrites GLastError.
      LFailure := 'Failed to switch to embedded database "' + AAliasPath +
                  '": ' + E.Message;

      // Attempt to rollback to the previous mode/target
      try
        FServerMode := LOldMode;
        FServerHost := LOldHost;
        FServerPort := LOldPort;
        FAliasName := LOldAlias;
        FAliasPath := LOldPath;
        FTablePassword := LOldPassword;
        FTablePasswordIsCommaList := LOldPasswordIsCommaList;
        FExtraTablePasswords := LOldExtraPasswords;
        nxWinsockTransport1.ServerName := LOldHost;
        nxWinsockTransport1.Port := LOldPort;
        if LOldPath <> '' then
          nxDatabase1.AliasPath := LOldPath
        else
          nxDatabase1.AliasName := LOldAlias;

        // Connect reports failure by returning False, not by raising.
        if not Reconnect then
          LFailure := LFailure + ' Rollback also failed: ' + GLastError;
      except
        on E2: Exception do
          LFailure := LFailure + ' Rollback also failed: ' + E2.Message;
      end;

      GLastError := WithFatalHint(LFailure);
      raise Exception.Create(GLastError);
    end;
  end;
end;

end.
