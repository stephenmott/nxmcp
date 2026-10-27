unit nxmcp.Resource.Server;

interface

uses
  System.SysUtils,
  MCPServer.Resource.Base;

type
  /// <summary>
  /// Data class for NexusDB server connection information
  /// </summary>
  TNexusDBServerInfo = class
  private
    FConnected: Boolean;
    FMode: string;
    FServerHost: string;
    FServerPort: Integer;
    FDatabaseAlias: string;
    FDatabaseAliasPath: string;
    FLastError: string;
    FFatal: Boolean;
  public
    property Connected: Boolean read FConnected write FConnected;
    property Mode: string read FMode write FMode;
    property ServerHost: string read FServerHost write FServerHost;
    property ServerPort: Integer read FServerPort write FServerPort;
    property DatabaseAlias: string read FDatabaseAlias write FDatabaseAlias;
    property DatabaseAliasPath: string read FDatabaseAliasPath write FDatabaseAliasPath;
    property LastError: string read FLastError write FLastError;
    /// <summary>NexusDB's fatal-error flag is set in this nxmcp process; restart it.</summary>
    property Fatal: Boolean read FFatal write FFatal;
  end;

  /// <summary>
  /// MCP Resource that exposes NexusDB connection status
  /// URI: nexusdb://server
  /// </summary>
  TNexusDBServerResource = class(TMCPResourceBase<TNexusDBServerInfo>)
  protected
    function GetResourceData: TNexusDBServerInfo; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  dmnx;

{ TNexusDBServerResource }

constructor TNexusDBServerResource.Create;
begin
  inherited;
  FURI := 'nexusdb://server';
  FName := 'nexusdb_server';
  FDescription := 'NexusDB server connection status and configuration';
  FMimeType := 'application/json';
end;

function TNexusDBServerResource.GetResourceData: TNexusDBServerInfo;
begin
  Result := TNexusDBServerInfo.Create;
  Result.Fatal := IsNexusFatal;

  if Assigned(nxmodule) then
  begin
    Result.Connected := nxmodule.IsConnected;
    Result.Mode := Tnxmodule.ModeToStr(nxmodule.ServerMode);
    Result.ServerHost := nxmodule.ServerHost;
    Result.ServerPort := nxmodule.ServerPort;
    Result.DatabaseAlias := nxmodule.AliasName;
    Result.DatabaseAliasPath := nxmodule.AliasPath;
    Result.LastError := nxmodule.GetLastError;
    if Result.Fatal then
      Result.LastError := WithFatalHint(Result.LastError);
  end
  else
  begin
    Result.Connected := False;
    Result.Mode := '';
    Result.ServerHost := '';
    Result.ServerPort := 0;
    Result.DatabaseAlias := '';
    Result.DatabaseAliasPath := '';
    Result.LastError := 'NexusDB module not initialized';
  end;
end;

initialization
  TMCPRegistry.RegisterResource('nexusdb://server',
    function: IMCPResource
    begin
      Result := TNexusDBServerResource.Create;
    end
  );

end.
