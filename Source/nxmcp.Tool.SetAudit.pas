unit nxmcp.Tool.SetAudit;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TSetAuditParams = class
  private
    FTableName: string;
    FUseAudit: Boolean;
    FIncludeBlobFields: Boolean;
    FClear: Boolean;
  public
    [SchemaDescription('Name of the table whose audit settings to set')]
    property TableName: string read FTableName write FTableName;

    [Optional]
    [SchemaDescription('When true, remove any existing audit descriptor and ignore other fields')]
    property Clear: Boolean read FClear write FClear;

    [Optional]
    [SchemaDescription('Enable audit-trail logging for changes to this table')]
    property UseAudit: Boolean read FUseAudit write FUseAudit;

    [Optional]
    [SchemaDescription('Include BLOB field values in the audit log (default false)')]
    property IncludeBlobFields: Boolean read FIncludeBlobFields write FIncludeBlobFields;
  end;

  TSetAuditTool = class(TMCPToolBase<TSetAuditParams>)
  protected
    function ExecuteWithParams(const Params: TSetAuditParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  nxsdTypes,
  nxsdDataDictionary,
  nxsdDataDictionaryAudit,
  nxsdDataDictionaryStrings,
  nxsdServerEngine,
  nxsdTableMapperDescriptor,
  nxllException,
  MCPServer.Registration,
  dmnx;

{ TSetAuditTool }

constructor TSetAuditTool.Create;
begin
  inherited;
  FName := 'set_audit';
  FTitle := 'Set Audit Settings';
  FDescription := 'Enable/disable audit-trail logging on a table and configure whether BLOB field changes are recorded. Pass clear=true to remove the audit descriptor entirely.';
end;

function TSetAuditTool.ExecuteWithParams(const Params: TSetAuditParams): string;
var
  LResultObj: TJSONObject;
  LOldDict, LNewDict: TnxDataDictionary;
  LMapper: TnxTableMapperDescriptor;
  LTaskInfo: TnxAbstractTaskInfo;
  LCompleted: Boolean;
  LTaskStatus: TnxTaskStatus;
  LAudit: TnxAuditDescriptor;
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
        LIdx := LNewDict.CustomDescsDescriptor.GetCustomDescriptorFromName(csAuditDescriptorName);
        if LIdx >= 0 then
          LNewDict.CustomDescsDescriptor.RemoveCustom(csAuditDescriptorName);
      end
      else
      begin
        LIdx := LNewDict.CustomDescsDescriptor.GetCustomDescriptorFromName(csAuditDescriptorName);
        if LIdx < 0 then
        begin
          LAudit := LNewDict.CustomDescsDescriptor.AddCustom(csAuditDescriptorName, TnxAuditDescriptor) as TnxAuditDescriptor;
        end
        else
          LAudit := LNewDict.CustomDescsDescriptor.CustomDescriptor[LIdx] as TnxAuditDescriptor;

        LAudit.UseAudit := Params.UseAudit;
        LAudit.IncludeBlobFields := Params.IncludeBlobFields;
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
      LResultObj.AddPair('useAudit', TJSONBool.Create(Params.UseAudit));
      LResultObj.AddPair('includeBlobFields', TJSONBool.Create(Params.IncludeBlobFields));
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
  TMCPRegistry.RegisterTool('set_audit',
    function: IMCPTool
    begin
      Result := TSetAuditTool.Create;
    end
  );

end.
