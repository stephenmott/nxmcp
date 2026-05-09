unit nxmcp.FieldTypes;

interface

uses
  nxsdTypes;

function StringToFieldType(const AType: string): TnxFieldType;

implementation

uses
  System.SysUtils;

function StringToFieldType(const AType: string): TnxFieldType;
var
  LType: string;
begin
  LType := LowerCase(AType);
  if      LType = 'boolean'     then Result := nxtBoolean
  else if LType = 'char'        then Result := nxtChar
  else if LType = 'widechar'    then Result := nxtWideChar
  else if LType = 'byte'        then Result := nxtByte
  else if LType = 'word'        then Result := nxtWord16
  else if LType = 'word32'      then Result := nxtWord32
  else if LType = 'int8'        then Result := nxtInt8
  else if LType = 'int16'       then Result := nxtInt16
  else if LType = 'integer'     then Result := nxtInt32
  else if LType = 'int64'       then Result := nxtInt64
  else if LType = 'autoinc'     then Result := nxtAutoInc
  else if LType = 'single'      then Result := nxtSingle
  else if LType = 'float'       then Result := nxtDouble
  else if LType = 'extended'    then Result := nxtExtended
  else if LType = 'currency'    then Result := nxtCurrency
  else if LType = 'date'        then Result := nxtDate
  else if LType = 'time'        then Result := nxtTime
  else if LType = 'datetime'    then Result := nxtDateTime
  else if LType = 'blob'        then Result := nxtBlob
  else if LType = 'memo'        then Result := nxtBlobMemo
  else if LType = 'graphic'     then Result := nxtBlobGraphic
  else if LType = 'bytearray'   then Result := nxtByteArray
  else if LType = 'shortstring' then Result := nxtShortString
  else if LType = 'nullstring'  then Result := nxtNullString
  else if LType = 'widestring'  then Result := nxtWideString
  else if LType = 'recrev'      then Result := nxtRecRev
  else if LType = 'guid'        then Result := nxtGuid
  else if LType = 'bcd'         then Result := nxtBCD
  else if LType = 'widememo'    then Result := nxtBlobWideMemo
  else if LType = 'fmtbcd'      then Result := nxtFmtBCD
  else if LType = 'refnr'       then Result := nxtRefNr
  else
    raise Exception.CreateFmt('Unknown field type: %s', [AType]);
end;

end.
