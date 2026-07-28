unit nxmcp.Tool.SetColumnDescription;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  TSetColumnDescriptionParams = class
  private
    FTableName: string;
    FColumnName: string;
    FDescription: string;
  public
    [SchemaDescription('Name of the table containing the column')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the column whose description to set')]
    property ColumnName: string read FColumnName write FColumnName;

    [SchemaDescription('New description text. Pass an empty string to clear the description.')]
    property Description: string read FDescription write FDescription;
  end;

  TSetColumnDescriptionTool = class(TSerializedToolBase<TSetColumnDescriptionParams>)
  protected
    function ExecuteWithParams(const Params: TSetColumnDescriptionParams): string; override;
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

{ TSetColumnDescriptionTool }

constructor TSetColumnDescriptionTool.Create;
begin
  inherited;
  FName := 'set_column_description';
  FTitle := 'Set Column Description';
  FDescription := 'Set or clear the description (comment) on a column. Pass an empty string to clear.';
end;

function TSetColumnDescriptionTool.ExecuteWithParams(const Params: TSetColumnDescriptionParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LFieldIdx: Integer;
begin
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.ColumnName) = '' then
    raise Exception.Create('Column name cannot be empty');

  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  nxmodule.nxSession1.CloseInactiveTables;

  LOldDict := TnxDataDictionary.Create;
  try
    nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

    LFieldIdx := LOldDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);
    if LFieldIdx < 0 then
      raise Exception.CreateFmt('Column "%s" not found in table "%s"', [Params.ColumnName, Params.TableName]);

    LNewDict := TnxDataDictionary.Create;
    try
      LNewDict.Assign(LOldDict);

      LFieldIdx := LNewDict.FieldsDescriptor.GetFieldFromName(Params.ColumnName);
      LNewDict.FieldsDescriptor.FieldDescriptor[LFieldIdx].fdDesc := Params.Description;

      if LOldDict.IsEqual(LNewDict) then
      begin
        LResultObj := TJSONObject.Create;
        try
          LResultObj.AddPair('success', TJSONBool.Create(True));
          LResultObj.AddPair('tableName', Params.TableName);
          LResultObj.AddPair('columnName', Params.ColumnName);
          LResultObj.AddPair('noChange', TJSONBool.Create(True));
          Result := LResultObj.ToJSON;
          Exit;
        finally
          LResultObj.Free;
        end;
      end;

      LMapper := TnxTableMapperDescriptor.Create;
      try
        LMapper.MapAllTablesAndFieldsByName(LOldDict, LNewDict);

        nxCheck(nxmodule.nxDatabase1.RestructureTableEx(Params.TableName, nxmodule.TablePassword,
          LNewDict, LMapper, LTaskInfo));

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

  LResultObj := TJSONObject.Create;
  try
    LResultObj.AddPair('success', TJSONBool.Create(True));
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('columnName', Params.ColumnName);
    LResultObj.AddPair('description', Params.Description);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('set_column_description',
    function: IMCPTool
    begin
      Result := TSetColumnDescriptionTool.Create;
    end
  );

end.
