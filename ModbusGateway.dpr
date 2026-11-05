program ModbusGateway;

uses
  Vcl.Forms,
  uMain in 'uMain.pas' {fmMain},
  uModbusProto in 'uModbusProto.pas',
  uSerialPort in 'uSerialPort.pas',
  uTcpClient in 'uTcpClient.pas',
  uGateway in 'uGateway.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfmMain, fmMain);
  Application.Run;
end.
