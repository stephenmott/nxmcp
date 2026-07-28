unit nxmcp.Tool.DropColumn;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  /// <summary>
  /// Parameters for the drop_column tool
  /// </summary>
  TDropColumnParams = class
  private
    FTableName: string;
    FColumnName: string;
  public
    [SchemaDescription('Name of the table containing the column')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the column to remove')]
    property ColumnName: string read FColumnName write FColumnName;
  end;

  /// <summary>
  /// MCP Tool that removes a column from a table
  /// </summary>
  TDropColumnTool = class(TSerializedToolBase<TDropColumnParams>)
  protected
    function ExecuteWithParams(const Params: TDropColumnParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdTypes,
  nxsdDataDictionary,
  nxsdServerEngine,
  nxsdTableMapperDescriptor,
  nxllException,
  MCPServer.Registration,
  dmnx;

{ TDropColumnTool }

constructor TDropColumnTool.Create;
begin
  inherited;
  FName := 'drop_column';
  FTitle := 'Drop Column';
  FDescription := 'Remove a column from an existing table. WARNING: This permanently deletes the column and its data.';
end;

function TDropColumnTool.ExecuteWithParams(const Params: TDropColumnParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LFieldIdx: Integer;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.ColumnName) = '' then
    raise Exception.Create('Column name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Close any open tables to avoid conflicts
  nxmodule.nxSession1.CloseInactiveTables;

  LOldDict := TnxDataDictionary.Create;
  try
    // Get existing dictionary
    nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

    // Check if column exists
    LFieldIdx := LOldDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);
    if LFieldIdx < 0 then
      raise Exception.CreateFmt('Column "%s" not found in table "%s"', [Params.ColumnName, Params.TableName]);

    // Create new dictionary without the column
    LNewDict := TnxDataDictionary.Create;
    try
      LNewDict.Assign(LOldDict);

      // Remove the field
      LFieldIdx := LNewDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);
      LNewDict.FieldsDescriptor.RemoveField(LFieldIdx);

      // Check if restructure is needed
      if LOldDict.IsEqual(LNewDict) then
        raise Exception.Create('No changes detected');

      // Create mapper and restructure
      LMapper := TnxTableMapperDescriptor.Create;
      try
        LMapper.MapAllTablesAndFieldsByName(LOldDict, LNewDict);

        nxCheck(nxmodule.nxDatabase1.RestructureTableEx(Params.TableName, nxmodule.TablePassword,
          LNewDict, LMapper, LTaskInfo));

        // Wait for completion
        if Assigned(LTaskInfo) then
        try
          while True do
          begin
            LTaskInfo.GetStatus(LCompleted, LTaskStatus);
            if LCompleted then
              Break;
            Sleep(100);
          end;
          nxCheck(LTaskStatus.tsErrorCode);
        finally
          LTaskInfo.Free;
        end;
      finally
        LMapper.Free;
      end;
    finally
      LNewDict.Free;
    end;
  finally
    LOldDict.Free;
  end;

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('columnName', Params.ColumnName);
    LResultObj.AddPair('message', 'Column removed successfully');
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('drop_column',
    function: IMCPTool
    begin
      Result := TDropColumnTool.Create;
    end
  );

end.
