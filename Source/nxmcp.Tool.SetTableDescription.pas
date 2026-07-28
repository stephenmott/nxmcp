unit nxmcp.Tool.SetTableDescription;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  TSetTableDescriptionParams = class
  private
    FTableName: string;
    FDescription: string;
  public
    [SchemaDescription('Name of the table whose description to set')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('New description text. Pass an empty string to clear the description.')]
    property Description: string read FDescription write FDescription;
  end;

  TSetTableDescriptionTool = class(TSerializedToolBase<TSetTableDescriptionParams>)
  protected
    function ExecuteWithParams(const Params: TSetTableDescriptionParams): string; override;
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

{ TSetTableDescriptionTool }

constructor TSetTableDescriptionTool.Create;
begin
  inherited;
  FName := 'set_table_description';
  FTitle := 'Set Table Description';
  FDescription := 'Set or clear the description (comment) on a table. Pass an empty string to clear.';
end;

function TSetTableDescriptionTool.ExecuteWithParams(const Params: TSetTableDescriptionParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
begin
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  nxmodule.nxSession1.CloseInactiveTables;

  LOldDict := TnxDataDictionary.Create;
  try
    nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

    LNewDict := TnxDataDictionary.Create;
    try
      LNewDict.Assign(LOldDict);

      LNewDict.FilesDescriptor.FileDescriptor[0].Desc := Params.Description;

      if LOldDict.IsEqual(LNewDict) then
      begin
        LResultObj := TJSONObject.Create;
        try
          LResultObj.AddPair('success', TJSONBool.Create(True));
          LResultObj.AddPair('tableName', Params.TableName);
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
    LResultObj.AddPair('description', Params.Description);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('set_table_description',
    function: IMCPTool
    begin
      Result := TSetTableDescriptionTool.Create;
    end
  );

end.
