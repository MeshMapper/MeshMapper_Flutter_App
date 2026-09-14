/// A device record from the public server-managed catalog.
class DeviceModel {
  final int id;
  final String manufacturer;
  final String shortName;
  final List<String> aliases;
  final double power;
  final String platform;
  final int txPower;
  final String notes;

  DeviceModel({
    required this.id,
    required this.manufacturer,
    required this.shortName,
    required List<String> aliases,
    required this.power,
    required this.platform,
    required this.txPower,
    required this.notes,
  }) : aliases = List.unmodifiable(aliases);

  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final manufacturer = json['manufacturer'];
    final shortName = json['shortName'];
    final aliases = json['aliases'];
    final power = json['power'];
    final platform = json['platform'];
    final txPower = json['txPower'];
    final notes = json['notes'];
    if (id is! int ||
        id < 0 ||
        manufacturer is! String ||
        shortName is! String ||
        aliases is! List ||
        aliases.any((value) => value is! String) ||
        power is! num ||
        !power.isFinite ||
        power <= 0 ||
        power > 100 ||
        platform is! String ||
        txPower is! int ||
        txPower < -30 ||
        txPower > 100 ||
        notes is! String) {
      throw const FormatException('Invalid device catalog record');
    }
    return DeviceModel(
      id: id,
      manufacturer: manufacturer,
      shortName: shortName,
      aliases: aliases.cast<String>(),
      power: power.toDouble(),
      platform: platform,
      txPower: txPower,
      notes: notes,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'manufacturer': manufacturer,
        'shortName': shortName,
        'aliases': aliases,
        'power': power,
        'platform': platform,
        'txPower': txPower,
        'notes': notes,
      };

  @override
  String toString() =>
      'DeviceModel($shortName, power=$power, txPower=$txPower)';
}
