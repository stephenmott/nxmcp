unit nxmcp.Tool.CopyTable;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the copy_table tool
  /// </summary>
  TCopyTableParams = class
  private
    FSourceTable: string;
    FTargetTable: string;
    FCopyData: Boolean;
  public
    [SchemaDescription('Name of the source table to copy from')]
    property SourceTable: string read FSourceTable write FSourceTable;

    [SchemaDescription('Name of the new table to create')]
    property TargetTable: string read FTargetTable write FTargetTable;

    [Optional]
    [SchemaDescription('If true, copy data as well as structure (default: false, structure only)')]
    property CopyData: Boolean read FCopyData write FCopyData;
  end;

  /// <summary>
  /// MCP Tool that copies a table structure (and optionally data)
  /// </summary>
  TCopyTableTool = class(TMCPToolBase<TCopyTableParams>)
  protected
    function ExecuteWithParams(const Params: TCopyTableParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdTypes,
  nxsdDataDictionary,
  nxllException,
  MCPServer.Registration,
  dmnx;

{ TCopyTableTool }

constructor TCopyTableTool.Create;
begin
  inherited;
  FName := 'copy_table';
  FTitle := 'Copy Table';
  FDescription := 'Copy a table structure to a new table. Optionally copy data as well.';
end;

function TCopyTableTool.ExecuteWithParams(const Params: TCopyTableParams): string;
var
  LResultObj: TJSONObject;
  LDict: TnxDataDictionary;
  LRowsCopied: Integer;
begin
  // Validate parameters
  if Trim(Params.SourceTable) = '' then
    raise Exception.Create('Source table name cannot be empty');

  if Trim(Params.TargetTable) = '' then
    raise Exception.Create('Target table name cannot be empty');

  if SameText(Params.SourceTable, Params.TargetTable) then
    raise Exception.Create('Source and target table names must be different');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  LRowsCopied := 0;
  nxmodule.ExecuteWithoutRetry(
    procedure
    begin
      // Close any open tables to avoid conflicts
      nxmodule.nxSession1.CloseInactiveTables;

      // Get source table dictionary
      LDict := TnxDataDictionary.Create;
      try
        nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.SourceTable,
          nxmodule.TablePassword, LDict));

        // Create the new table with same structure
        nxmodule.nxDatabase1.CreateTable(False, Params.TargetTable, '', LDict);
      finally
        LDict.Free;
      end;

      // Table creation is not transactional, so neither it nor the copy may be
      // replayed automatically after a communication failure.
      if Params.CopyData then
      begin
        nxmodule.nxQuery1.Close;
        nxmodule.nxQuery1.SQL.Text := 'INSERT INTO "' + Params.TargetTable +
          '" SELECT * FROM "' + Params.SourceTable + '"';
        nxmodule.nxQuery1.ExecSQL;
        LRowsCopied := nxmodule.nxQuery1.RowsAffected;
      end;
    end);

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('sourceTable', Params.SourceTable);
    LResultObj.AddPair('targetTable', Params.TargetTable);
    LResultObj.AddPair('dataCopied', TJSONBool.Create(Params.CopyData));
    if Params.CopyData then
      LResultObj.AddPair('rowsCopied', TJSONNumber.Create(LRowsCopied));
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('copy_table',
    function: IMCPTool
    begin
      Result := TCopyTableTool.Create;
    end
  );

end.
