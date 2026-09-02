unit nxmcp.CapabilityFilter;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  MCPServer.Types;

type
  /// <summary>
  /// Decides whether a tool name / resource URI is switched on.
  /// </summary>
  TnxIsEnabledFunc = reference to function(const AName: string): Boolean;

  /// <summary>
  /// Wraps a capability manager and hides whatever the configuration switched off.
  ///
  /// The MCP library builds its manager's tool/resource table once, in the
  /// manager's constructor, straight from TMCPRegistry - and the registry has no
  /// unregister. Rather than patch the library (nxmcp already asks builders for
  /// one patched dependency, which is enough), the filtering sits in front of it.
  ///
  /// Two layers, deliberately:
  ///  * the invoke method (tools/call, resources/read) is refused by NAME, before
  ///    the inner manager sees it. This is the layer that actually enforces, and
  ///    it does not depend on the shape of any response.
  ///  * the list method has the disabled entries stripped from the response, so
  ///    clients never offer them. If the response ever stops matching the
  ///    expected shape this raises rather than passing the full list through -
  ///    and even then the invoke layer above still refuses the call.
  /// </summary>
  TnxFilteredManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    FInner: IMCPCapabilityManager;
    FIsEnabled: TnxIsEnabledFunc;
    FListMethod: string;
    FItemsKey: string;
    FItemNameKey: string;
    FInvokeMethod: string;
    FInvokeParamKey: string;
    FWhat: string;
    procedure FilterListResponse(const AValue: TValue);
  public
    constructor Create(const AInner: IMCPCapabilityManager;
      const AIsEnabled: TnxIsEnabledFunc;
      const AListMethod, AItemsKey, AItemNameKey, AInvokeMethod,
            AInvokeParamKey, AWhat: string);

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
  end;

/// <summary>
/// Wraps a tools manager: filters tools/list, refuses tools/call for disabled tools.
/// </summary>
function FilterTools(const AInner: IMCPCapabilityManager;
  const AIsEnabled: TnxIsEnabledFunc): IMCPCapabilityManager;

/// <summary>
/// Wraps a resources manager: filters resources/list, refuses resources/read for
/// disabled resources.
/// </summary>
function FilterResources(const AInner: IMCPCapabilityManager;
  const AIsEnabled: TnxIsEnabledFunc): IMCPCapabilityManager;

implementation

function FilterTools(const AInner: IMCPCapabilityManager;
  const AIsEnabled: TnxIsEnabledFunc): IMCPCapabilityManager;
begin
  Result := TnxFilteredManager.Create(AInner, AIsEnabled,
    'tools/list', 'tools', 'name', 'tools/call', 'name', 'Tool');
end;

function FilterResources(const AInner: IMCPCapabilityManager;
  const AIsEnabled: TnxIsEnabledFunc): IMCPCapabilityManager;
begin
  Result := TnxFilteredManager.Create(AInner, AIsEnabled,
    'resources/list', 'resources', 'uri', 'resources/read', 'uri', 'Resource');
end;

{ TnxFilteredManager }

constructor TnxFilteredManager.Create(const AInner: IMCPCapabilityManager;
  const AIsEnabled: TnxIsEnabledFunc;
  const AListMethod, AItemsKey, AItemNameKey, AInvokeMethod,
        AInvokeParamKey, AWhat: string);
begin
  inherited Create;
  FInner := AInner;
  FIsEnabled := AIsEnabled;
  FListMethod := AListMethod;
  FItemsKey := AItemsKey;
  FItemNameKey := AItemNameKey;
  FInvokeMethod := AInvokeMethod;
  FInvokeParamKey := AInvokeParamKey;
  FWhat := AWhat;
end;

function TnxFilteredManager.GetCapabilityName: string;
begin
  Result := FInner.GetCapabilityName;
end;

function TnxFilteredManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := FInner.HandlesMethod(Method);
end;

procedure TnxFilteredManager.FilterListResponse(const AValue: TValue);
var
  LObj: TJSONObject;
  LItems: TJSONArray;
  LItem: TJSONValue;
  LNameValue: TJSONValue;
  I: Integer;
begin
  if AValue.IsEmpty or not AValue.IsType<TJSONObject> then
    raise Exception.Create('Unexpected ' + FListMethod + ' response: not a JSON object. ' +
      'nxmcp cannot hide the disabled entries, so it is refusing to answer.');

  LObj := AValue.AsType<TJSONObject>;
  if not (LObj.GetValue(FItemsKey) is TJSONArray) then
    raise Exception.Create('Unexpected ' + FListMethod + ' response: no "' + FItemsKey +
      '" array. nxmcp cannot hide the disabled entries, so it is refusing to answer.');

  LItems := LObj.GetValue(FItemsKey) as TJSONArray;

  // Backwards: Remove() shifts everything after the removed element.
  for I := LItems.Count - 1 downto 0 do
  begin
    LItem := LItems.Items[I];
    if not (LItem is TJSONObject) then
      Continue;
    LNameValue := TJSONObject(LItem).GetValue(FItemNameKey);
    if not Assigned(LNameValue) then
      Continue;
    if not FIsEnabled(LNameValue.Value) then
      // Remove hands ownership of the element back to us.
      LItems.Remove(I).Free;
  end;
end;

function TnxFilteredManager.ExecuteMethod(const Method: string;
  const Params: TJSONObject): TValue;
var
  LNameValue: TJSONValue;
  LName: string;
begin
  // Enforce first, by name: this is what actually keeps a disabled capability
  // unreachable, and it holds regardless of what any response looks like.
  if SameText(Method, FInvokeMethod) and Assigned(Params) then
  begin
    LNameValue := Params.GetValue(FInvokeParamKey);
    if Assigned(LNameValue) then
    begin
      LName := LNameValue.Value;
      if (LName <> '') and not FIsEnabled(LName) then
        raise Exception.Create(FWhat + ' "' + LName + '" is disabled in nxmcp.ini. ' +
          'Enable it under [' + FWhat + 's] to use it.');
    end;
  end;

  Result := FInner.ExecuteMethod(Method, Params);

  if SameText(Method, FListMethod) then
    FilterListResponse(Result);
end;

end.
