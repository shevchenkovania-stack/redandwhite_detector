/// Публичный API пакета `lamp_detection`.
///
/// Только export'ы — приложения (включая example/ и Tournament Live) обязаны
/// импортировать именно этот файл, а не src/**.
library;

export 'src/camera/camera_frame_source.dart';
export 'src/camera/frame_source.dart';
export 'src/delivery/hit_event_sender.dart';
export 'src/delivery/mock_hit_event_sender.dart';
export 'src/detection/exposure_guard.dart';
export 'src/detection/feature_extractor.dart';
export 'src/detection/hit_state_machine.dart';
export 'src/detection/lamp_calibration.dart';
export 'src/detection/lamp_detector.dart';
export 'src/detection/response_model.dart';
export 'src/diagnostics/diagnostics_collector.dart';
export 'src/diagnostics/feature_csv_recorder.dart';
export 'src/diagnostics/run_analyzer.dart';
export 'src/models/frame_features.dart';
export 'src/models/hit_event.dart';
export 'src/models/lamp_config.dart';
export 'src/models/roi.dart';
export 'src/session/detection_session.dart';
export 'src/session/settings_store.dart';
export 'src/storage/event_repository.dart';
export 'src/storage/sqlite_event_repository.dart';
