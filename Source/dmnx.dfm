object nxmodule: Tnxmodule
  OnCreate = DataModuleCreate
  OnDestroy = DataModuleDestroy
  Height = 480
  Width = 640
  object nxDatabase1: TnxDatabase
    Session = nxSession1
    Left = 69
    Top = 177
  end
  object nxSession1: TnxSession
    ServerEngine = nxRemoteServerEngine1
    Left = 68
    Top = 119
  end
  object nxTable1: TnxTable
    Database = nxDatabase1
    Left = 446
    Top = 104
  end
  object nxQuery1: TnxQuery
    Database = nxDatabase1
    Left = 294
    Top = 206
  end
  object nxRemoteServerEngine1: TnxRemoteServerEngine
    Transport = nxWinsockTransport1
    Left = 158
    Top = 92
  end
  object nxWinsockTransport1: TnxWinsockTransport
    DisplayCategory = 'Transports'
    MulticastGroup = 'ff02::4e58:4442'
    Left = 75
    Top = 33
  end
  object dsTable1: TDataSource
    DataSet = nxTable1
    Left = 472
    Top = 150
  end
  object dsQuery1: TDataSource
    DataSet = nxQuery1
    Left = 355
    Top = 246
  end
end
