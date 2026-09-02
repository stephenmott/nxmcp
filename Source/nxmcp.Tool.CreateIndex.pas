unit nxmcp.Tool.CreateIndex;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  /// <summary>
  /// Parameters for the create_index tool
  /// </summary>
  TCreateIndexParams = class
  private
    FTableName: string;
    FIndexName: string;
    FColumns: string;
    FUnique: Boolean;
  public
    [SchemaDescription('Name of the table to create the index on')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name for the new index')]
    property IndexName: string read FIndexName write FIndexName;

    [SchemaDescription('Column name(s) for the index. Single column: "ColumnName". Multiple columns: "Col1,Col2"')]
    property Columns: string read FColumns write FColumns;

    [Optional]
    [SchemaDescription('Create a unique index (default: false)')]
    property Unique: Boolean read FUnique write FUnique;
  end;

  /// <summary>
  /// MCP Tool that creates an index on a table
  /// </summary>
  TCreateIndexTool = class(TMCPToolBase<TCreateIndexParams>)
  protected
    function ExecuteWithParams(const Params: TCreateIndexParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.Classes,
  nxsdTypes,
  nxsdDataDictionary,
  nxsdServerEngine,
  nxsdTableMapperDescriptor,
  nxllException,
  MCPServer.Registration,
  dmnx;

{ TCreateIndexTool }

constructor TCreateIndexTool.Create;
begin
  inherited;
  FName := 'create_index';
  FTitle := 'Create Index';
  FDescription := 'Create an index on one or more columns of a table.';
end;

function TCreateIndexTool.ExecuteWithParams(const Params: TCreateIndexParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LNewIndex: TnxIndexDescriptor;
  LColumnList: TStringList;
  LFieldIdx: Integer;
  LDups: TnxIndexDups;
  I: Integer;
begin
  try
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.IndexName) = '' then
    raise Exception.Create('Index name cannot be empty');

  if Trim(Params.Columns) = '' then
    raise Exception.Create('At least one column must be specified');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  // Close any open tables to avoid conflicts
  nxmodule.nxSession1.CloseInactiveTables;

  LColumnList := TStringList.Create;
  try
    LColumnList.StrictDelimiter := True;
    LColumnList.CommaText := Params.Columns;

    if LColumnList.Count = 0 then
      raise Exception.Create('At least one column must be specified');

    LOldDict := TnxDataDictionary.Create;
    try
      // Get existing dictionary
      nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

      // Verify all columns exist
      for I := 0 to LColumnList.Count - 1 do
      begin
        LFieldIdx := LOldDict.FieldsDescriptor.GetFieldFromName(Trim(LColumnList[I]));
        if LFieldIdx < 0 then
          raise Exception.CreateFmt('Column "%s" not found in table "%s"', [Trim(LColumnList[I]), Params.TableName]);
      end;

      // Create new dictionary with added index
      LNewDict := TnxDataDictionary.Create;
      try
        LNewDict.Assign(LOldDict);

        // Add the new index. NexusDB's idDups semantics: idNone = no duplicates
        // (unique index), idAll = duplicates allowed (non-unique).
        if Params.Unique then
          LDups := idNone
        else
          LDups := idAll;
        LNewIndex := LNewDict.IndicesDescriptor.AddIndex(Params.IndexName, 0, LDups, '', TnxCompKeyDescriptor);

        // Add columns to index
        for I := 0 to LColumnList.Count - 1 do
        begin
          LFieldIdx := LNewDict.FieldsDescriptor.GetFieldFromName(Trim(LColumnList[I]));
          TnxCompKeyDescriptor(LNewIndex.KeyDescriptor).Add(LFieldIdx);
        end;

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
  finally
    LColumnList.Free;
  end;

  // Build result
  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('indexName', Params.IndexName);
    LResultObj.AddPair('columns', Params.Columns);
    LResultObj.AddPair('unique', TJSONBool.Create(Params.Unique));
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
  except
    on E: Exception do
    begin
      if Assigned(nxmodule) then
        nxmodule.RecoverSessionAfterError(E);
      raise;
    end;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('create_index',
    function: IMCPTool
    begin
      Result := TCreateIndexTool.Create;
    end
  );

end.
