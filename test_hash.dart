import 'dart:convert';
import 'package:crypto/crypto.dart';

int getChannelHash(String name) {
  final bytes = utf8.encode(name);
  final hash = sha256.convert(bytes);
  return hash.bytes[0];
}

void main() {
  const target = 0xd8;

  // ignore: avoid_print
  print('Looking for channel that hashes to 0xd8 ($target decimal)\n');

  // Test common variations
  final tests = [
    '#wartest',
    '#WarTest',
    '#WARTEST',
    '#wartest ',  // trailing space
    ' #wartest',  // leading space
    '#war-test',
    '#war_test',
    '#wardrive',
    '#testing',
    '#ottawa',
    'wartest',
    '#test',
    '#war',
  ];

  for (final name in tests) {
    final hash = getChannelHash(name);
    final match = hash == target ? '✅ MATCH!' : '';
    // ignore: avoid_print
    print('${name.padRight(20)} -> 0x${hash.toRadixString(16).padLeft(2, '0')} ($hash) $match');
  }
}
