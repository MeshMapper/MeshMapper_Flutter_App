import 'companion_transport.dart';
import 'web_serial_service.dart';

Future<CompanionTransport> openWebSerialTransport() async {
  final service = WebSerialService();
  await service.openConnection();
  return service;
}
