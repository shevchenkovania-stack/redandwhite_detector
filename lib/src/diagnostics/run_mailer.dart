/// Отправка законченного прогона на почту стенда.
///
/// CSV с покадровыми признаками — единственное, чем можно пересчитать решение
/// после прогона, а на стенде нет ни кабеля, ни человека, который умеет что-то
/// выгружать. Поэтому прогон уходит сам, как только жмут «Стоп», и уходит туда,
/// где его увидят: письмом на стендовый ящик.
///
/// Форма сознательно старая: SMTP поверх TLS и обычное MIME-письмо. Своего
/// приёмника не нужно, письмо открывается в любой почте, а вложения читаются
/// теми же инструментами, что и локальные файлы. Секрет в репозиторий не
/// попадает: пароль приложения приходит сборкой (`--dart-define`), и сменить
/// ящик значит пересобрать APK с другими аргументами.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Куда и от кого писать.
///
/// Пустой логин или пароль = отключено: без ящика прогон живёт ровно так же,
/// как жил до этой возможности, и очередь копить ничего не будет.
class MailConfig {
  const MailConfig({
    this.host = '',
    this.port = 465,
    this.user = '',
    this.password = '',
    this.from = '',
    this.to = '',
  });

  /// Из аргументов сборки: `--dart-define=LAMP_MAIL_HOST=smtp.yandex.ru` и
  /// так далее. `LAMP_MAIL_PORT` — число, записанное строкой.
  factory MailConfig.fromBuild() {
    final int? port = int.tryParse(
      const String.fromEnvironment('LAMP_MAIL_PORT'),
    );
    return MailConfig(
      host: const String.fromEnvironment('LAMP_MAIL_HOST'),
      port: port ?? 465,
      user: const String.fromEnvironment('LAMP_MAIL_USER'),
      password: const String.fromEnvironment('LAMP_MAIL_PASS'),
      from: const String.fromEnvironment('LAMP_MAIL_FROM'),
      to: const String.fromEnvironment('LAMP_MAIL_TO'),
    );
  }

  final String host;
  final int port;
  final String user;
  final String password;

  /// От кого. У Яндекса конверт обязан совпадать с аутентифицированным
  /// логином, поэтому по умолчанию это [user].
  final String from;

  /// Кому. По умолчанию — самому себе: один ящик и отправляет, и принимает, и
  /// никому на стенде не надо знать чужие адреса.
  final String to;

  String get sender => from.isNotEmpty ? from : user;

  String get recipient => to.isNotEmpty ? to : user;

  /// Есть ли чем и куда отправлять.
  bool get isEnabled =>
      host.isNotEmpty && user.isNotEmpty && password.isNotEmpty;
}

/// Один файл внутри письма.
class RunAttachment {
  const RunAttachment(this.name, this.bytes, this.contentType);

  final String name;
  final List<int> bytes;
  final String contentType;

  int get size => bytes.length;
}

/// Готовое письмо прогона: тема, читаемый текст и файлы.
class RunPackage {
  const RunPackage({
    required this.runId,
    required this.subject,
    required this.body,
    required this.attachments,
  });

  /// Идентификатор прогона — он же имя каталога в очереди, он же ключ повтора:
  /// второе письмо с тем же `runId` сервер посчитает дублем, а не новым прогоном.
  final String runId;

  /// Тема: дата, режим, счётчики — то, по чему прогон находится в почте.
  final String subject;

  /// Текст письма словами: чем считал, что получилось, чего не хватает.
  final String body;

  final List<RunAttachment> attachments;

  int get totalBytes =>
      attachments.fold(0, (int sum, RunAttachment a) => sum + a.size);

  Map<String, Object?> toJson() => <String, Object?>{
    'runId': runId,
    'subject': subject,
    'body': body,
    'attachments': attachments
        .map(
          (RunAttachment a) => <String, Object?>{
            'name': a.name,
            'contentType': a.contentType,
          },
        )
        .toList(),
  };
}

/// Ошибка SMTP: код ответа (0 — значит не код, а обрыв или таймаут) и строка,
/// на которой всё сломалось.
class SmtpException implements Exception {
  const SmtpException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'SmtpException($code): $message';
}

/// Функция отправки — вставка для теста, чтобы гонять очередь без сервера.
typedef SmtpSend = Future<void> Function(MailConfig config, RunPackage pkg);

/// Тип содержимого по расширению: почту интересуют не все файлы поровну, а
/// `features.csv` и `baseline.json` открываются сразу, поэтому тип угадывается
/// по имени, а не тащится отдельным полем.
String contentTypeOf(String name) {
  if (name.endsWith('.csv')) {
    return 'text/csv';
  }
  if (name.endsWith('.json')) {
    return 'application/json';
  }
  if (name.endsWith('.txt') || name.endsWith('.log')) {
    return 'text/plain';
  }
  return 'application/octet-stream';
}

/// Собирает письмо прогона из готового текста и текстовых вложений.
///
/// Тему и тело считает сессия — только она знает, чем считался прогон и
/// сколько чего набралось. Здесь вложения лежат строками: CSV, калибровка и
/// настройки — всё текст, и, если их читать одним `readAsString` и тем же
/// `utf8.encode` обратно, байты на диске и байты в письме совпадают.
RunPackage assembleRunPackage({
  required String runId,
  required String subject,
  required String body,
  Map<String, String> textFiles = const <String, String>{},
}) {
  final List<RunAttachment> attachments = <RunAttachment>[
    for (final MapEntry<String, String> e in textFiles.entries)
      RunAttachment(e.key, utf8.encode(e.value), contentTypeOf(e.key)),
  ];
  return RunPackage(
    runId: runId,
    subject: subject,
    body: body,
    attachments: attachments,
  );
}

/// Минимальный SMTP поверх TLS: EHLO, AUTH LOGIN, MAIL FROM, RCPT TO, DATA,
/// QUIT — ровно то, чем пишется одно письмо.
class SmtpTransport {
  static Future<void> send(
    MailConfig config,
    RunPackage pkg, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (!config.isEnabled) {
      throw const SmtpException(0, 'Ящик для отправки не настроен');
    }
    final SecureSocket socket = await SecureSocket.connect(
      config.host,
      config.port,
      timeout: timeout,
    );
    final _SmtpPipe pipe = _SmtpPipe(socket);
    try {
      await pipe.reply(<int>{220}, timeout);
      await pipe.command('EHLO lamp-detection', <int>{250}, timeout);
      await pipe.command('AUTH LOGIN', <int>{334}, timeout);
      await pipe.command(
        base64Encode(utf8.encode(config.user)),
        <int>{334},
        timeout,
      );
      await pipe.command(
        base64Encode(utf8.encode(config.password)),
        <int>{235},
        timeout,
      );
      await pipe.command('MAIL FROM:<${config.sender}>', <int>{250}, timeout);
      await pipe.command(
        'RCPT TO:<${config.recipient}>',
        <int>{250, 251},
        timeout,
      );
      await pipe.command('DATA', <int>{354}, timeout);
      // Тело письма заканчивается строкой из одной точки (RFC 5321).
      await pipe.write('${buildMessage(config, pkg)}\r\n.');
      await pipe.reply(<int>{250}, timeout);
      await pipe.command('QUIT', <int>{221}, timeout);
    } finally {
      await pipe.close();
    }
  }

  /// Письмо целиком. Всё в base64: кириллица в теме и теле тогда не зависит от
  /// того, как почтовый клиент перекодирует строки, а CSV не побьётся о
  /// «точка в начале строки».
  static String buildMessage(MailConfig config, RunPackage pkg) {
    final String boundary =
        'lamp${pkg.runId.replaceAll(RegExp(r'[^0-9A-Za-z]'), '')}';
    final StringBuffer text = StringBuffer()
      ..write('From: ${config.sender}\r\n')
      ..write('To: ${config.recipient}\r\n')
      ..write('Subject: ${_encoded(pkg.subject)}\r\n')
      ..write('MIME-Version: 1.0\r\n')
      ..write('Content-Type: multipart/mixed; boundary="$boundary"\r\n')
      ..write('\r\n')
      ..write('--$boundary\r\n')
      ..write('Content-Type: text/plain; charset=UTF-8\r\n')
      ..write('Content-Transfer-Encoding: base64\r\n')
      ..write('\r\n')
      ..write(_wrapped(base64Encode(utf8.encode(pkg.body))))
      ..write('\r\n');
    for (final RunAttachment a in pkg.attachments) {
      text
        ..write('--$boundary\r\n')
        ..write('Content-Type: ${a.contentType}; name="${a.name}"\r\n')
        ..write('Content-Disposition: attachment; filename="${a.name}"\r\n')
        ..write('Content-Transfer-Encoding: base64\r\n')
        ..write('\r\n')
        ..write(_wrapped(base64Encode(a.bytes)))
        ..write('\r\n');
    }
    text.write('--$boundary--\r\n');
    return text.toString();
  }

  /// Тема по RFC 2047, иначе кириллица в заголовке уезжает mojibake.
  static String _encoded(String value) =>
      '=?UTF-8?B?${base64Encode(utf8.encode(value))}?=';

  /// base64 режут на строки по 76 символов — столько требует RFC 2045 и
  /// столько принимает любой сервер без разрыва строки.
  static String _wrapped(String value) {
    const int width = 76;
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < value.length; i += width) {
      final int end = i + width < value.length ? i + width : value.length;
      out
        ..write(value.substring(i, end))
        ..write('\r\n');
    }
    return out.toString();
  }
}

/// Построчное чтение ответа сервера.
///
/// Ответ бывает многострочным (`250-…` продолжается, `250 ` последний),
/// поэтому [reply] читает блок целиком и возвращает код последней строки.
class _SmtpPipe {
  _SmtpPipe(this._socket) {
    _sub = utf8
        .decoder
        .bind(_socket)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: _onError,
          onDone: () => _onError(const SmtpException(0, 'Соединение закрыто сервером')),
        );
  }

  final SecureSocket _socket;
  late final StreamSubscription<String> _sub;
  final List<String> _lines = <String>[];
  final List<Completer<String>> _waiters = <Completer<String>>[];

  /// Обрыв соединения или ошибка декодирования: ждущий ответ читатель обязан
  /// получить её, а не висеть до таймаута.
  Object? _error;

  void _onLine(String line) {
    if (_waiters.isEmpty) {
      _lines.add(line);
      return;
    }
    _waiters.removeAt(0).complete(line);
  }

  void _onError(Object error) {
    _error ??= error;
    while (_waiters.isNotEmpty) {
      _waiters.removeAt(0).completeError(error);
    }
  }

  Future<String> _readLine(Duration timeout) async {
    if (_lines.isNotEmpty) {
      return _lines.removeAt(0);
    }
    if (_error != null) {
      throw _error!;
    }
    final Completer<String> waiter = Completer<String>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      timeout,
      onTimeout: () =>
          throw SmtpException(0, 'Сервер не ответил за ${timeout.inSeconds} с'),
    );
  }

  /// Читает блок ответа и проверяет, что его код лежит среди ожидаемых.
  Future<void> reply(Set<int> expected, Duration timeout) async {
    int code = 0;
    while (true) {
      final String line = await _readLine(timeout);
      code = int.tryParse(line.length >= 3 ? line.substring(0, 3) : '') ?? 0;
      if (line.length < 4 || line[3] != '-') {
        break;
      }
    }
    if (!expected.contains(code)) {
      throw SmtpException(code, 'Неожиданный ответ SMTP');
    }
  }

  Future<void> command(String line, Set<int> expected, Duration timeout) async {
    _socket.write('$line\r\n');
    await _socket.flush();
    await reply(expected, timeout);
  }

  Future<void> write(String message) async {
    _socket.write('$message\r\n');
    await _socket.flush();
  }

  Future<void> close() async {
    await _sub.cancel();
    try {
      await _socket.close();
    } on Object {
      // Сокет мог закрыться сам — на результат отправки это не влияет.
    }
  }
}

/// Очередь прогонов, которые ещё не ушли на почту.
///
/// Каталог лежит рядом с CSV. Не ушло — осталось и дойдёт при следующем
/// пуске, поэтому пропавшая сеть стоит стенду «не дошло пока», а не потерянный
/// прогон. Файлы копируются внутрь очереди сразу, и правило уборки «оставить
/// три CSV» перестаёт быть угрозой: копия живёт, пока её не подтвердили.
class RunMailer {
  RunMailer({
    required Directory directory,
    required this.config,
    this.onLog,
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 5),
    SmtpSend? send,
  }) : _root = directory,
       _send = send ?? SmtpTransport.send;

  static const String folderName = 'lamp_outbox';

  /// Сколько раз отправить одно письмо, прежде чем оставить его в очереди.
  /// Стоп не обязан висеть из-за сети, поэтому на стенде хватает и одного.
  final int maxAttempts;

  /// Пауза между попытками растёт: 5 с, 10 с… При заглушке в тесте — ноль.
  final Duration retryDelay;

  final Directory _root;
  final MailConfig config;
  final void Function(String message)? onLog;
  final SmtpSend _send;

  Future<void> _log(String message) async => onLog?.call(message);

  /// Кладёт прогон в очередь и тут же пытается отправить. `true` — письмо
  /// ушло и очередь по нему закрыта.
  Future<bool> submit(RunPackage pkg) async {
    if (!_root.existsSync()) {
      await _root.create(recursive: true);
    }
    final Directory run = Directory(p.join(_root.path, pkg.runId));
    await run.create(recursive: true);
    for (final RunAttachment a in pkg.attachments) {
      await File(p.join(run.path, a.name)).writeAsBytes(a.bytes, flush: true);
    }
    await File(p.join(run.path, 'package.json')).writeAsString(
      jsonEncode(pkg.toJson()),
      flush: true,
    );
    await _log(
      'Прогон ${pkg.runId}: ${pkg.attachments.length} файла, '
      '${(pkg.totalBytes / 1024).toStringAsFixed(0)} КБ — отправляю',
    );
    return _attempt(run, pkg);
  }

  /// Досылает всё, что не ушло. Вызывается при старте сессии; при первой же
  /// неудаче встаёт — без сети незачем перебирать весь список.
  Future<void> resendPending() async {
    if (!config.isEnabled || !_root.existsSync()) {
      return;
    }
    final List<Directory> pending = _root
        .listSync()
        .whereType<Directory>()
        .toList()
      ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    for (final Directory run in pending) {
      final RunPackage? pkg = await _load(run);
      if (pkg == null) {
        continue;
      }
      if (!await _attempt(run, pkg)) {
        return;
      }
    }
  }

  Future<bool> _attempt(Directory run, RunPackage pkg) async {
    if (!config.isEnabled) {
      await _log('Почта не настроена — прогон ${pkg.runId} лежит в очереди');
      return false;
    }
    for (int i = 0; i < maxAttempts; i++) {
      try {
        await _send(config, pkg);
        await run.delete(recursive: true);
        await _log('Прогон ${pkg.runId} отправлен на ${config.recipient}');
        return true;
      } on Object catch (e) {
        await _log(
          'Отправка ${pkg.runId} не удалась (попытка ${i + 1}/$maxAttempts): $e',
        );
        if (i + 1 < maxAttempts) {
          await Future<void>.delayed(retryDelay * (i + 1));
        }
      }
    }
    await _log('Прогон ${pkg.runId} остался в очереди — дойдёт при следующем пуске');
    return false;
  }

  Future<RunPackage?> _load(Directory run) async {
    final File manifest = File(p.join(run.path, 'package.json'));
    if (!manifest.existsSync()) {
      return null;
    }
    try {
      final Map<String, Object?> json = (
        jsonDecode(await manifest.readAsString()) as Map
      ).cast<String, Object?>();
      final List<RunAttachment> attachments = <RunAttachment>[];
      for (final Object? raw in (json['attachments'] as List? ?? <Object?>[])) {
        final Map<String, Object?> a = (raw as Map).cast<String, Object?>();
        final String name = a['name'] as String;
        final File f = File(p.join(run.path, name));
        if (!f.existsSync()) {
          continue;
        }
        attachments.add(
          RunAttachment(
            name,
            await f.readAsBytes(),
            a['contentType'] as String? ?? 'application/octet-stream',
          ),
        );
      }
      return RunPackage(
        runId: json['runId'] as String? ?? p.basename(run.path),
        subject: json['subject'] as String? ?? '',
        body: json['body'] as String? ?? '',
        attachments: attachments,
      );
    } on Object catch (e) {
      await _log('Очередь: повреждён ${p.basename(run.path)}: $e');
      return null;
    }
  }

  /// Сколько прогонов ещё не ушло.
  int get pendingCount => _root.existsSync()
      ? _root.listSync().whereType<Directory>().length
      : 0;
}
