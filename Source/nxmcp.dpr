// JCL_DEBUG_EXPERT_GENERATEJDBG OFF
// JCL_DEBUG_EXPERT_INSERTJDBG OFF
program nxmcp;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.SyncObjs,
  Winapi.Windows,
  MCPServer.Types,
  MCPServer.IdHTTPServer,
  MCPServer.StdioTransport,
  MCPServer.Logger,
  MCPServer.Settings,
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager,
  dmnx in 'dmnx.pas' {nxmodule: TDataModule},
  nxmcp.FieldTypes in 'nxmcp.FieldTypes.pas',
  nxmcp.Resource.Server in 'nxmcp.Resource.Server.pas',
  nxmcp.Resource.Tables in 'nxmcp.Resource.Tables.pas',
  nxmcp.Resource.Schema in 'nxmcp.Resource.Schema.pas',
  nxmcp.Tool.ExecuteQuery in 'nxmcp.Tool.ExecuteQuery.pas',
  nxmcp.Tool.GetTableSchema in 'nxmcp.Tool.GetTableSchema.pas',
  // Phase 3 - Data Manipulation
  nxmcp.Tool.ExecuteSQL in 'nxmcp.Tool.ExecuteSQL.pas',
  nxmcp.Tool.GetTableData in 'nxmcp.Tool.GetTableData.pas',
  nxmcp.Tool.InsertRecord in 'nxmcp.Tool.InsertRecord.pas',
  nxmcp.Tool.UpdateRecords in 'nxmcp.Tool.UpdateRecords.pas',
  nxmcp.Tool.DeleteRecords in 'nxmcp.Tool.DeleteRecords.pas',
  // Phase 4 - Schema Management
  nxmcp.Tool.CreateTable in 'nxmcp.Tool.CreateTable.pas',
  nxmcp.Tool.DropTable in 'nxmcp.Tool.DropTable.pas',
  nxmcp.Tool.CopyTable in 'nxmcp.Tool.CopyTable.pas',
  nxmcp.Tool.RenameTable in 'nxmcp.Tool.RenameTable.pas',
  nxmcp.Tool.AddColumn in 'nxmcp.Tool.AddColumn.pas',
  nxmcp.Tool.DropColumn in 'nxmcp.Tool.DropColumn.pas',
  nxmcp.Tool.ModifyColumn in 'nxmcp.Tool.ModifyColumn.pas',
  nxmcp.Tool.CreateIndex in 'nxmcp.Tool.CreateIndex.pas',
  nxmcp.Tool.DropIndex in 'nxmcp.Tool.DropIndex.pas',
  // Phase 5 - Table Maintenance
  nxmcp.Tool.EmptyTable in 'nxmcp.Tool.EmptyTable.pas',
  nxmcp.Tool.PackTable in 'nxmcp.Tool.PackTable.pas',
  nxmcp.Tool.ReindexTable in 'nxmcp.Tool.ReindexTable.pas',
  nxmcp.Tool.RecoverTable in 'nxmcp.Tool.RecoverTable.pas',
  nxmcp.Tool.ChangePassword in 'nxmcp.Tool.ChangePassword.pas',
  nxmcp.Tool.GetAutoIncValue in 'nxmcp.Tool.GetAutoIncValue.pas',
  // Phase 6 - Transactions
  nxmcp.Tool.BatchExecute in 'nxmcp.Tool.BatchExecute.pas',
  // Phase 7 - Utility
  nxmcp.Tool.ListTables in 'nxmcp.Tool.ListTables.pas',
  nxmcp.Tool.CountRecords in 'nxmcp.Tool.CountRecords.pas',
  nxmcp.Tool.ListIndexes in 'nxmcp.Tool.ListIndexes.pas',
  nxmcp.Tool.ExplainQuery in 'nxmcp.Tool.ExplainQuery.pas',
  // Phase 8 - Database Management
  nxmcp.Tool.ListAliases in 'nxmcp.Tool.ListAliases.pas',
  nxmcp.Tool.SwitchDatabase in 'nxmcp.Tool.SwitchDatabase.pas',
  nxmcp.Tool.SwitchServer in 'nxmcp.Tool.SwitchServer.pas';

var
  Server: TMCPIdHTTPServer;
  Settings: TMCPSettings;
  ManagerRegistry: IMCPManagerRegistry;
  CoreManager: IMCPCapabilityManager;
  ShutdownEvent: TEvent;

function ConsoleCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  Result := True;
  case dwCtrlType of
    CTRL_C_EVENT,
    CTRL_BREAK_EVENT,
    CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT,
    CTRL_SHUTDOWN_EVENT:
    begin
      TLogger.Info('Shutdown signal received');
      if Assigned(ShutdownEvent) then
        ShutdownEvent.SetEvent;
    end;
  end;
end;

function HasStdioFlag: Boolean;
var
  I: Integer;
  Param: string;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    Param := ParamStr(I).ToLower;
    if (Param = '--stdio') or (Param = '-stdio') or (Param = '/stdio') then
    begin
      Result := True;
      Break;
    end;
  end;
end;

procedure InitializeNexusDB;
begin
  TLogger.Info('Initializing NexusDB connection...');
  nxmodule := Tnxmodule.Create(nil);

  if nxmodule.IsConnected then
    TLogger.Info('Connected to NexusDB: ' + nxmodule.AliasName +
                 ' @ ' + nxmodule.ServerHost + ':' + IntToStr(nxmodule.ServerPort))
  else
  begin
    TLogger.Warning('Not connected to NexusDB');
    if nxmodule.GetLastError <> '' then
      TLogger.Warning('  Error: ' + nxmodule.GetLastError);
  end;
end;

procedure CreateManagerRegistry;
begin
  Settings := TMCPSettings.Create(nxmodule.GetConfigPath);
  ManagerRegistry := TMCPManagerRegistry.Create;
  CoreManager := TMCPCoreManager.Create(Settings);
  ManagerRegistry.RegisterManager(CoreManager);
  ManagerRegistry.RegisterManager(TMCPToolsManager.Create);
  ManagerRegistry.RegisterManager(TMCPResourcesManager.Create);
end;

procedure RunHTTPServer;
begin
  TLogger.Info('nxmcp - NexusDB MCP Server');
  TLogger.Info('==========================');
  TLogger.Info('Transport: HTTP');

  Server := TMCPIdHTTPServer.Create(nil);
  try
    Server.Settings := Settings;
    Server.ManagerRegistry := ManagerRegistry;
    Server.CoreManager := CoreManager;
    Server.Start;

    TLogger.Info('MCP Server running on http://' + Settings.Host + ':' +
                 IntToStr(Settings.Port) + Settings.Endpoint);
    TLogger.Info('Press CTRL+C to stop...');

    ShutdownEvent.WaitFor(INFINITE);

    TLogger.Info('Shutting down server...');
    Server.Stop;
    TLogger.Info('Server stopped successfully');
  finally
    Server.Free;
  end;
end;

procedure RunStdioServer;
var
  StdioTransport: TMCPStdioTransport;
begin
  TLogger.Info('nxmcp - NexusDB MCP Server');
  TLogger.Info('==========================');
  TLogger.Info('Transport: STDIO');

  StdioTransport := TMCPStdioTransport.Create(ManagerRegistry, CoreManager);
  try
    StdioTransport.Run;
  finally
    StdioTransport.Free;
  end;
end;

begin
  // Detect STDIO mode before any output - stdout is reserved for JSON-RPC
  if HasStdioFlag then
    TLogger.UseStdErr := True;

  // Configure logger
  TLogger.LogToConsole := True;
  TLogger.MinLogLevel := TLogLevel.Info;

  ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;

  // Create shutdown event
  ShutdownEvent := TEvent.Create(nil, True, False, '');
  try
    // Set up Windows console signal handler
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);

    try
      // Initialize NexusDB (shared by both transport modes)
      InitializeNexusDB;
      try
        // Initialize MCP infrastructure (shared by both transport modes)
        CreateManagerRegistry;
        try
          // Route to appropriate transport
          if HasStdioFlag then
            RunStdioServer
          else
            RunHTTPServer;
        finally
          Settings.Free;
        end;
      finally
        nxmodule.Free;
      end;
    except
      on E: Exception do
        TLogger.Error(E);
    end;

    // Remove signal handler
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
  finally
    ShutdownEvent.Free;
  end;
end.
