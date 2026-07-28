unit nxmcp.Tool.SetIndexDescription;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  TSetIndexDescriptionParams = class
  private
    FTableName: string;
    FIndexName: string;
    FDescription: string;
  public
    [SchemaDescription('Name of the table containing the index')]
    property TableName: string read FTableName write FTableName;

    [SchemaDescription('Name of the index whose description to set')]
    property IndexName: string read FIndexName write FIndexName;

    [SchemaDescription('New description text. Pass an empty string to clear the description.')]
    property Description: string read FDescription write FDescription;
  end;

  TSetIndexDescriptionTool = class(TSerializedToolBase<TSetIndexDescriptionParams>)
  protected
    function ExecuteWithParams(const Params: TSetIndexDescriptionParams): string; override;
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

{ TSetIndexDescriptionTool }

constructor TSetIndexDescriptionTool.Create;
begin
  inherited;
  FName := 'set_index_description';
  FTitle := 'Set Index Description';
  FDescription := 'Set or clear the description (comment) on an index. Pass an empty string to clear.';
end;

type
  TnxCrackIndexDescriptor = class(TnxIndexDescriptor);

function FindIndexFromName(const ADict: TnxDataDictionary; const AName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if not Assigned(ADict.IndicesDescriptor) then
    Exit;
  for I := 0 to ADict.IndicesDescriptor.IndexCount - 1 do
    if SameText(ADict.IndicesDescriptor.IndexDescriptor[I].Name, AName) then
      Exit(I);
end;

function TSetIndexDescriptionTool.ExecuteWithParams(const Params: TSetIndexDescriptionParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LIndexIdx: Integer;
begin
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  if Trim(Params.IndexName) = '' then
    raise Exception.Create('Index name cannot be empty');

  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  nxmodule.nxSession1.CloseInactiveTables;

  LOldDict := TnxDataDictionary.Create;
  try
    nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(Params.TableName, nxmodule.TablePassword, LOldDict));

    LIndexIdx := FindIndexFromName(LOldDict, Params.IndexName);
    if LIndexIdx < 0 then
      raise Exception.CreateFmt('Index "%s" not found in table "%s"', [Params.IndexName, Params.TableName]);

    LNewDict := TnxDataDictionary.Create;
    try
      LNewDict.Assign(LOldDict);

      LIndexIdx := FindIndexFromName(LNewDict, Params.IndexName);
      TnxCrackIndexDescriptor(LNewDict.IndicesDescriptor.IndexDescriptor[LIndexIdx]).idDesc := Params.Description;

      if LOldDict.IsEqual(LNewDict) then
      begin
        LResultObj := TJSONObject.Create;
        try
          LResultObj.AddPair('success', TJSONBool.Create(True));
          LResultObj.AddPair('tableName', Params.TableName);
          LResultObj.AddPair('indexName', Params.IndexName);
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
    LResultObj.AddPair('indexName', Params.IndexName);
    LResultObj.AddPair('description', Params.Description);
    Result := LResultObj.ToJSON;
  finally
    LResultObj.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('set_index_description',
    function: IMCPTool
    begin
      Result := TSetIndexDescriptionTool.Create;
    end
  );

end.
