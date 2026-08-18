class BrainData {
  final int attention;
  final int meditation;
  final int signal;
  final int delta;
  final int theta;
  final int lowAlpha;
  final int highAlpha;
  final int lowBeta;
  final int highBeta;
  final int lowGamma;
  final int middleGamma;
  final int battery;
  final int gravityX;
  final int gravityY;
  final int gravityZ;
  final int blink;
  final int heartRate;
  final int grind;
  final bool isDistracted;

  BrainData({
    required this.attention,
    required this.meditation,
    required this.signal,
    required this.delta,
    required this.theta,
    required this.lowAlpha,
    required this.highAlpha,
    required this.lowBeta,
    required this.highBeta,
    required this.lowGamma,
    required this.middleGamma,
    required this.battery,
    required this.gravityX,
    required this.gravityY,
    required this.gravityZ,
    required this.blink,
    required this.heartRate,
    required this.grind,
    required this.isDistracted,
  });

  factory BrainData.fromMap(Map<dynamic, dynamic> map) {
    return BrainData(
      attention: map['attention'] ?? 0,
      meditation: map['meditation'] ?? 0,
      signal: map['signal'] ?? 100,
      delta: map['delta'] ?? 0,
      theta: map['theta'] ?? 0,
      lowAlpha: map['lowAlpha'] ?? 0,
      highAlpha: map['highAlpha'] ?? 0,
      lowBeta: map['lowBeta'] ?? 0,
      highBeta: map['highBeta'] ?? 0,
      lowGamma: map['lowGamma'] ?? 0,
      middleGamma: map['middleGamma'] ?? 0,
      battery: map['battery'] ?? 0,
      gravityX: map['gravityX'] ?? 0,
      gravityY: map['gravityY'] ?? 0,
      gravityZ: map['gravityZ'] ?? 0,
      blink: map['blink'] ?? 0,
      heartRate: map['heartRate'] ?? 0,
      grind: map['grind'] ?? 0,
      isDistracted: map['isDistracted'] ?? false,
    );
  }
}
