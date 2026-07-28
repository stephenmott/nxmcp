unit nxmcp.Tool.ListIndexes;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  nxmcp.SerializedAccess;

type
  /// <summary>
  /// Parameters for the list_indexes tool
  /// </summary>
  TListIndexesParams = class
  private
    FTableName: string;
  public
    [SchemaDescription('Name of the table to list indexes for')]
    property TableName: string read FTableName write FTableName;
  end;

  /// <summary>
  /// MCP Tool that lists all indexes for a table.
  /// </summary>
  TListIndexesTool = class(TSerializedToolBase<TListIndexesParams>)
  protected
    function ExecuteWithParams(const Params: TListIndexesParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  Data.DB,
  DataSet.Serialize,
  nxsdTypes,
  nxsdDataDictionary,
  nxllException,
  MCPServer.Registration,
  dmnx;

type
  TnxCrackIndexDescriptor = class(TnxIndexDescriptor);

{ TListIndexesTool }

constructor TListIndexesTool.Create;
begin
  inherited;
  FName := 'list_indexes';
  FTitle := 'List Table Indexes';
  FDescription := 'List all indexes defined on a table, including name, uniqueness, and whether it is the default index.';
end;

function TListIndexesTool.ExecuteWithParams(const Params: TListIndexesParams): string;
var
  LResultObj: TJSONObject;
  LIndexesArray: TJSONArray;
  LIndexObj: TJSONObject;
  LFieldsArray: TJSONArray;
  LDict: TnxDataDictionary;
  LIndex: TnxIndexDescriptor;
  LKeyDesc: TnxCompKeyDescriptor;
  I, J: Integer;
begin
  // Validate parameters
  if Trim(Params.TableName) = '' then
    raise Exception.Create('Table name cannot be empty');

  // Check connection
  if not Assigned(nxmodule) or not nxmodule.EnsureConnection then
    raise Exception.Create('Not connected to NexusDB');

  LResultObj := TJSONObject.Create;
  try
    LIndexesArray := TJSONArray.Create;

    LDict := TnxDataDictionary.Create;
    try
      // Auto-reconnects and retries once on lost connection
      nxmodule.ExecuteWithReconnect(
        procedure
        begin
          nxCheck(nxmodule.nxDatabase1.GetDataDictionaryEx(
            Params.TableName, nxmodule.TablePassword, LDict));
        end);

      if Assigned(LDict.IndicesDescriptor) then
      begin
        for I := 0 to LDict.IndicesDescriptor.IndexCount - 1 do
        begin
          LIndex := LDict.IndicesDescriptor.IndexDescriptor[I];
          LIndexObj := TJSONObject.Create;
          LIndexObj.AddPair('name', LIndex.Name);
          LIndexObj.AddPair('unique', TJSONBool.Create(LIndex.Dups = idNone));
          LIndexObj.AddPair('isDefault', TJSONBool.Create(
            LDict.IndicesDescriptor.DefaultIndex = LIndex.Number));
          LIndexObj.AddPair('description', TnxCrackIndexDescriptor(LIndex).idDesc);

          // Get fields for this index
          LFieldsArray := TJSONArray.Create;
          if LIndex.KeyDescriptor is TnxCompKeyDescriptor then
          begin
            LKeyDesc := TnxCompKeyDescriptor(LIndex.KeyDescriptor);
            for J := 0 to LKeyDesc.KeyFieldCount - 1 do
            begin
              if LKeyDesc.KeyFields[J].FieldNumber >= 0 then
                LFieldsArray.Add(LKeyDesc.KeyFields[J].Field.Name);
            end;
          end;
          LIndexObj.AddPair('fields', LFieldsArray);

          LIndexesArray.AddElement(LIndexObj);
        end;
      end;
    finally
      LDict.Free;
    end;

    // Build result
    LResultObj.AddPair('tableName', Params.TableName);
    LResultObj.AddPair('indexCount', TJSONNumber.Create(LIndexesArray.Count));
    LResultObj.AddPair('indexes', LIndexesArray);
    Result := LResultObj.ToJSON;
  except
    LResultObj.Free;
    raise;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('list_indexes',
    function: IMCPTool
    begin
      Result := TListIndexesTool.Create;
    end
  );

end.
