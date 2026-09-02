unit nxmcp.Tool.SetDataPolicies;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TSetDataPoliciesParams = class
  private
    FTableName: string;
    FDenyInsert: Boolean;
    FDenyModify: Boolean;
    FDenyDelete: Boolean;
    FMinRecordCount: Integer;
    FMaxRecordCount: Integer;
    FClear: Boolean;
  public
    [SchemaDescription('Name of the table whose data policies to set')]
    property TableName: string read FTableName write FTableName;

    [Optional]
    [SchemaDescription('When true, remove any existing data-policies descriptor and ignore other fields')]
    property Clear: Boolean read FClear write FClear;

    [Optional]
    [SchemaDescription('Reject INSERT operations on this table')]
    property DenyInsert: Boolean read FDenyInsert write FDenyInsert;

    [Optional]
    [SchemaDescription('Reject UPDATE/MODIFY operations on this table')]
    property DenyModify: Boolean read FDenyModify write FDenyModify;

    [Optional]
    [SchemaDescription('Reject DELETE operations on this table')]
    property DenyDelete: Boolean read FDenyDelete write FDenyDelete;

    [Optional]
    [SchemaDescription('Minimum record count to enforce. 0 means no minimum.')]
    property MinRecordCount: Integer read FMinRecordCount write FMinRecordCount;

    [Optional]
    [SchemaDescription('Maximum record count to enforce. 0 means no maximum.')]
    property MaxRecordCount: Integer read FMaxRecordCount write FMaxRecordCount;
  end;

  TSetDataPoliciesTool = class(TMCPToolBase<TSetDataPoliciesParams>)
  protected
    function ExecuteWithParams(const Params: TSetDataPoliciesParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdTypes,
  nxsdDataDictionary,
  nxsdDataDictionaryDataPolicies,
  nxsdDataDictionaryStrings,
  nxsdServerEngine,
  nxsdTableMapperDescriptor,
  nxllException,
  MCPServer.Registration,
  dmnx;

{ TSetDataPoliciesTool }

constructor TSetDataPoliciesTool.Create;
begin
  inherited;
  FName := 'set_data_policies';
  FTitle := 'Set Data Policies';
  FDescription := 'Configure table-level data policies: deny insert/modify/delete and enforce min/max record counts. Pass clear=true to remove the policy descriptor entirely.';
end;

function TSetDataPoliciesTool.ExecuteWithParams(const Params: TSetDataPoliciesParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LDP: TnxDataPoliciesDescriptor;
  LOps: TnxRecordOperations;
  LIdx: Integer;
begin
  try
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

      if Params.Clear then
      begin
        LIdx := LNewDict.CustomDescsDescriptor.GetCustomDescriptorFromName(csDataPolicies);
        if LIdx >= 0 then
          LNewDict.CustomDescsDescriptor.RemoveCustom(csDataPolicies);
      end
      else
      begin
        LDP := EnsureDataPoliciesDescriptor(LNewDict);

        LOps := [];
        if Params.DenyInsert then Include(LOps, TnxRecordOperation.roInsert);
        if Params.DenyModify then Include(LOps, TnxRecordOperation.roModify);
        if Params.DenyDelete then Include(LOps, TnxRecordOperation.roDelete);

        LDP.DenyRecordOperations := LOps;
        LDP.MinRecordCount := Params.MinRecordCount;
        LDP.MaxRecordCount := Params.MaxRecordCount;
      end;

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
    if Params.Clear then
      LResultObj.AddPair('cleared', TJSONBool.Create(True))
    else
    begin
      LResultObj.AddPair('denyInsert', TJSONBool.Create(Params.DenyInsert));
      LResultObj.AddPair('denyModify', TJSONBool.Create(Params.DenyModify));
      LResultObj.AddPair('denyDelete', TJSONBool.Create(Params.DenyDelete));
      LResultObj.AddPair('minRecordCount', TJSONNumber.Create(Params.MinRecordCount));
      LResultObj.AddPair('maxRecordCount', TJSONNumber.Create(Params.MaxRecordCount));
    end;
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
  TMCPRegistry.RegisterTool('set_data_policies',
    function: IMCPTool
    begin
      Result := TSetDataPoliciesTool.Create;
    end
  );

end.
