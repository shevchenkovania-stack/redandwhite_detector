import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/frame_features.dart';
import '../models/lamp_config.dart';
import '../models/roi.dart';

/// Сохранение ROI, калибровки и порогов в `shared_preferences`.
///
/// Всё лежит в трёх JSON-строках и одном флаге: ключей специально мало, чтобы
/// не зависеть от типа значений и не плодить мусор при смене формата.
class SettingsStore {
  SettingsStore(this._prefs);

  static const String _roiKey = 'lamp_detection.roi';
  static const String _baselineKey = 'lamp_detection.baseline';
  static const String _configKey = 'lamp_detection.config';
  static const String _sessionKey = 'lamp_detection.session_id';
  static const String _roiSyncKey = 'lamp_detection.roi_sync_size';

  final SharedPreferences _prefs;

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  RoiLayout? readRoi() {
    final String? raw = _prefs.getString(_roiKey);
    if (raw == null) {
      return null;
    }
    try {
      return RoiLayout.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }

  Future<void> writeRoi(RoiLayout roi) =>
      _prefs.setString(_roiKey, jsonEncode(roi.toJson()));

  /// Замок размера рамок: `true` — размер один на обе зоны. Это настройка
  /// наводки, а не детектора, поэтому живёт здесь, а не в `LampConfig`.
  bool readRoiSyncSize() => _prefs.getBool(_roiSyncKey) ?? false;

  Future<void> writeRoiSyncSize(bool sync) => _prefs.setBool(_roiSyncKey, sync);

  LampBaseline? readBaseline() {
    final String? raw = _prefs.getString(_baselineKey);
    if (raw == null) {
      return null;
    }
    try {
      return LampBaseline.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }

  Future<void> writeBaseline(LampBaseline baseline) =>
      _prefs.setString(_baselineKey, jsonEncode(baseline.toJson()));

  Future<void> clearBaseline() => _prefs.remove(_baselineKey);

  LampConfig? readConfig() {
    final String? raw = _prefs.getString(_configKey);
    if (raw == null) {
      return null;
    }
    try {
      return LampConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }

  Future<void> writeConfig(LampConfig config) =>
      _prefs.setString(_configKey, jsonEncode(config.toJson()));

  String? readSessionId() => _prefs.getString(_sessionKey);

  Future<void> writeSessionId(String sessionId) =>
      _prefs.setString(_sessionKey, sessionId);
}
