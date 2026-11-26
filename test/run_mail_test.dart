import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Проверки ровно того, за что отправка отвечает: письмо собирается, очередь
/// держит прогон до подтверждения и отдаёт его после. Настоящий SMTP-сервер
/// тут не нужен и не трогается — транспорт подменяется вставкой.
void main() {
  final MailConfig mail = MailConfig(
    host: 'smtp.example.test',
    user: 'bench@example.test',
    password: 'secret',
  );

  RunPackage package(String id) => RunPackage(
    runId: id,
    subject: 'LAMP прогон $id',
    body: 'Чем считали: hsv+prof',
    attachments: <RunAttachment>[
      RunAttachment('features.csv', utf8.encode('a,b\n1,2\n'), 'text/csv'),
    ],
  );

  group('письмо прогона', () {
    test('тема и вложения уходят в base64, тело — текст', () {
      final String message = SmtpTransport.buildMessage(mail, package('r1'));
      expect(message, contains('Subject: =?UTF-8?B?'));
      expect(message, contains('Content-Type: multipart/mixed;'));
      expect(message, contains('filename="features.csv"'));
      // Кириллица в теме не должна остаться открытым текстом.
      expect(message, isNot(contains('Subject: LAMP прогон')));
      expect(message, isNot(contains('Content-Transfer-Encoding: 8bit')));
    });

    test('имя файла определяет тип содержимого', () {
      expect(contentTypeOf('features.csv'), 'text/csv');
      expect(contentTypeOf('baseline.json'), 'application/json');
      expect(contentTypeOf('log.txt'), 'text/plain');
      expect(contentTypeOf('frame.bin'), 'application/octet-stream');
    });
  });

  group('очередь недоотправленных', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('lamp_outbox'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('без подтверждения сервера прогон остаётся и досылается', () async {
      final List<String> sent = <String>[];
      final RunMailer mailer = RunMailer(
        directory: dir,
        config: mail,
        maxAttempts: 1,
        retryDelay: Duration.zero,
        send: (MailConfig _, RunPackage pkg) async {
          if (sent.isEmpty) {
            sent.add(pkg.runId);
            throw const SmtpException(451, 'сервер не принимает');
          }
          sent.add(pkg.runId);
        },
      );
      expect(await mailer.submit(package('r2')), isFalse);
      expect(mailer.pendingCount, 1);
      await mailer.resendPending();
      expect(sent, <String>['r2', 'r2']);
      expect(mailer.pendingCount, 0);
    });

    test('настроенный ящик — единственное условие отправки', () {
      expect(mail.isEnabled, isTrue);
      expect(const MailConfig(host: 'smtp.example.test').isEnabled, isFalse);
      expect(MailConfig.fromBuild().isEnabled, isFalse);
    });
  });
}
