object fmMain: TfmMain
  Left = 0
  Top = 0
  Caption = #1064#1083#1102#1079' Modbus RTU <-> TCP'
  ClientHeight = 560
  ClientWidth = 720
  Color = clBtnFace
  Constraints.MinHeight = 520
  Constraints.MinWidth = 600
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnClose = FormClose
  OnCreate = FormCreate
  DesignSize = (
    720
    560)
  TextHeight = 15
  object shpStatus: TShape
    Left = 172
    Top = 154
    Width = 17
    Height = 17
    Brush.Color = clSilver
    Pen.Color = clGray
    Shape = stCircle
  end
  object lbStatus: TLabel
    Left = 206
    Top = 154
    Width = 130
    Height = 17
    AutoSize = False
    Caption = #1054#1089#1090#1072#1085#1086#1074#1083#1077#1085
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object lbStats: TLabel
    Left = 360
    Top = 154
    Width = 352
    Height = 17
    Alignment = taRightJustify
    Anchors = [akLeft, akTop, akRight]
    AutoSize = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clGrayText
    Font.Height = -12
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
  end
  object gbCom: TGroupBox
    Left = 8
    Top = 8
    Width = 344
    Height = 130
    Caption = #1055#1086#1088#1090' Modbus RTU ('#1079#1072#1087#1088#1086#1089#1099' '#1084#1072#1089#1090#1077#1088#1072')'
    TabOrder = 0
    object lbPort: TLabel
      Left = 16
      Top = 34
      Width = 28
      Height = 15
      Caption = #1055#1086#1088#1090
    end
    object lbBaud: TLabel
      Left = 16
      Top = 66
      Width = 52
      Height = 15
      Caption = #1057#1082#1086#1088#1086#1089#1090#1100
    end
    object lbDataBits: TLabel
      Left = 204
      Top = 66
      Width = 71
      Height = 15
      Caption = #1041#1080#1090#1099' '#1076#1072#1085#1085#1099#1093
    end
    object lbParity: TLabel
      Left = 16
      Top = 98
      Width = 50
      Height = 15
      Caption = #1063#1105#1090#1085#1086#1089#1090#1100
    end
    object lbStopBits: TLabel
      Left = 204
      Top = 98
      Width = 60
      Height = 15
      Caption = #1057#1090#1086#1087'-'#1073#1080#1090#1099
    end
    object cbPort: TComboBox
      Left = 76
      Top = 30
      Width = 110
      Height = 23
      Style = csDropDownList
      TabOrder = 0
    end
    object btnRefreshPorts: TButton
      Left = 196
      Top = 29
      Width = 132
      Height = 25
      Caption = #1054#1073#1085#1086#1074#1080#1090#1100' '#1089#1087#1080#1089#1086#1082
      TabOrder = 1
      OnClick = btnRefreshPortsClick
    end
    object cbBaud: TComboBox
      Left = 76
      Top = 62
      Width = 110
      Height = 23
      ItemIndex = 3
      TabOrder = 2
      Text = '9600'
      Items.Strings = (
        '1200'
        '2400'
        '4800'
        '9600'
        '14400'
        '19200'
        '38400'
        '57600'
        '115200')
    end
    object cbDataBits: TComboBox
      Left = 276
      Top = 62
      Width = 52
      Height = 23
      Style = csDropDownList
      ItemIndex = 0
      TabOrder = 3
      Text = '8'
      Items.Strings = (
        '8'
        '7')
    end
    object cbParity: TComboBox
      Left = 76
      Top = 94
      Width = 110
      Height = 23
      Style = csDropDownList
      ItemIndex = 0
      TabOrder = 4
      Text = #1053#1077#1090
      Items.Strings = (
        #1053#1077#1090
        #1053#1077#1095#1105#1090#1085#1072#1103
        #1063#1105#1090#1085#1072#1103
        #1052#1077#1090#1082#1072' (1)'
        #1055#1088#1086#1073#1077#1083' (0)')
    end
    object cbStopBits: TComboBox
      Left = 276
      Top = 94
      Width = 52
      Height = 23
      Style = csDropDownList
      ItemIndex = 0
      TabOrder = 5
      Text = '1'
      Items.Strings = (
        '1'
        '1.5'
        '2')
    end
  end
  object gbTcp: TGroupBox
    Left = 360
    Top = 8
    Width = 352
    Height = 130
    Anchors = [akLeft, akTop, akRight]
    Caption = #1059#1089#1090#1088#1086#1081#1089#1090#1074#1086' Modbus TCP ('#1089#1077#1088#1074#1077#1088')'
    TabOrder = 1
    object lbHost: TLabel
      Left = 16
      Top = 34
      Width = 46
      Height = 15
      Caption = 'IP-'#1072#1076#1088#1077#1089
    end
    object lbTcpPort: TLabel
      Left = 216
      Top = 34
      Width = 28
      Height = 15
      Caption = #1055#1086#1088#1090
    end
    object lbTimeout: TLabel
      Left = 16
      Top = 66
      Width = 110
      Height = 15
      Caption = #1058#1072#1081#1084'-'#1072#1091#1090' '#1086#1090#1074#1077#1090#1072', '#1084#1089
    end
    object edHost: TEdit
      Left = 70
      Top = 30
      Width = 136
      Height = 23
      TabOrder = 0
      Text = '192.168.0.10'
    end
    object edPort: TEdit
      Left = 250
      Top = 30
      Width = 60
      Height = 23
      TabOrder = 1
      Text = '502'
    end
    object edTimeout: TEdit
      Left = 250
      Top = 62
      Width = 60
      Height = 23
      TabOrder = 2
      Text = '1000'
    end
    object chkCache: TCheckBox
      Left = 16
      Top = 97
      Width = 209
      Height = 17
      Caption = #1050#1101#1096' '#1095#1090#1077#1085#1080#1103' f03/f04'
      TabOrder = 3
    end
  end
  object btnStart: TButton
    Left = 16
    Top = 146
    Width = 140
    Height = 32
    Caption = #1057#1090#1072#1088#1090
    Default = True
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
    TabOrder = 2
    OnClick = btnStartClick
  end
  object gbLog: TGroupBox
    Left = 8
    Top = 186
    Width = 704
    Height = 366
    Anchors = [akLeft, akTop, akRight, akBottom]
    Caption = #1046#1091#1088#1085#1072#1083' '#1086#1073#1084#1077#1085#1072
    TabOrder = 3
    DesignSize = (
      704
      366)
    object memLog: TMemo
      Left = 8
      Top = 20
      Width = 688
      Height = 298
      Anchors = [akLeft, akTop, akRight, akBottom]
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -11
      Font.Name = 'Consolas'
      Font.Style = []
      ParentFont = False
      ReadOnly = True
      ScrollBars = ssVertical
      TabOrder = 0
      WordWrap = False
    end
    object chkLog: TCheckBox
      Left = 16
      Top = 334
      Width = 200
      Height = 17
      Anchors = [akLeft, akBottom]
      Caption = #1042#1077#1089#1090#1080' '#1078#1091#1088#1085#1072#1083' '#1086#1073#1084#1077#1085#1072
      Checked = True
      State = cbChecked
      TabOrder = 1
    end
    object btnClearLog: TButton
      Left = 486
      Top = 329
      Width = 100
      Height = 27
      Anchors = [akRight, akBottom]
      Caption = #1054#1095#1080#1089#1090#1080#1090#1100
      TabOrder = 2
      OnClick = btnClearLogClick
    end
    object btnSaveLog: TButton
      Left = 592
      Top = 329
      Width = 104
      Height = 27
      Anchors = [akRight, akBottom]
      Caption = #1057#1086#1093#1088#1072#1085#1080#1090#1100#8230
      TabOrder = 3
      OnClick = btnSaveLogClick
    end
  end
  object dlgSave: TSaveDialog
    DefaultExt = 'log'
    FileName = 'gateway.log'
    Filter = #1046#1091#1088#1085#1072#1083' (*.log)|*.log|'#1042#1089#1077' '#1092#1072#1081#1083#1099' (*.*)|*.*'
    Options = [ofOverwritePrompt, ofEnableSizing]
    Left = 600
    Top = 248
  end
  object tmrUi: TTimer
    Interval = 300
    OnTimer = tmrUiTimer
    Left = 552
    Top = 240
  end
end
