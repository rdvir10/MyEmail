import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/speech/speech_engine.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/speech_text.dart';
import 'package:myemail/state/read_aloud.dart';

/// Read Aloud: the open message read out in the phone's own voice, Hebrew
/// in a Hebrew one, a paragraph at a time.
void main() {
  group('what is read', () {
    test('the subject, then each paragraph, lines of one joined', () {
      final pieces = speechPieces(
        subject: 'Delivery on Sunday',
        body: 'Hi Ron,\n\nThe truck comes\nat nine.\n\nThanks',
      );
      expect(pieces.map((p) => p.text), [
        'Delivery on Sunday',
        'Hi Ron,',
        'The truck comes at nine.',
        'Thanks',
      ]);
      expect(pieces.every((p) => p.language == englishVoice), isTrue);
    });

    test('a web address is "link", a rule is nothing, a quote loses its >',
        () {
      final pieces = speechPieces(
        body: 'See https://example.com/a/very/long/path?x=1 for details.\n\n'
            '--------\n\n'
            '> Can you come?\n> Tomorrow is fine.',
      );
      expect(pieces.map((p) => p.text), [
        'See link for details.',
        'Can you come? Tomorrow is fine.',
      ]);
    });

    test('Hebrew in a Hebrew voice, English in an English one', () {
      final pieces = speechPieces(
        subject: 'הצעת מחיר',
        body: 'שלום רון, מצורפת ההצעה.\n\nRegards, Dana\n\n12345',
      );
      expect(pieces.map((p) => p.language), [
        hebrewVoice,
        hebrewVoice,
        englishVoice,
        // Numbers alone go on in the voice before them.
        englishVoice,
      ]);
    });

    test('a long paragraph is cut between sentences', () {
      final sentence = 'This sentence is about forty-five characters. ';
      final pieces = speechPieces(body: sentence * 30);
      expect(pieces.length, greaterThan(2));
      expect(pieces.every((p) => p.text.length <= maxPieceLength), isTrue);
      expect(pieces.every((p) => p.text.endsWith('.')), isTrue);
    });
  });

  group('reading', () {
    late FakeSpeechEngine voice;
    late ProviderContainer c;
    late ReadAloud reader;

    final message = MailMessage(
      id: 'a:INBOX#1',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: 1,
      subject: 'Plan',
      from: const MailAddress(email: 'x@example.com'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );
    const body = MailBody(text: 'First.\n\nSecond.\n\nThird.');

    setUp(() {
      voice = FakeSpeechEngine();
      c = ProviderContainer(
        overrides: [speechEngineProvider.overrideWithValue(voice)],
      );
      addTearDown(c.dispose);
      reader = c.read(readAloudProvider.notifier);
    });

    ReadAloudState? state() => c.read(readAloudProvider);

    test('goes from piece to piece, and stops at the end', () async {
      await reader.start(message, body);
      expect(voice.said.map((s) => s.text), ['Plan']);
      for (final expected in ['First.', 'Second.', 'Third.']) {
        voice.finish();
        await Future<void>.delayed(Duration.zero);
        expect(voice.said.last.text, expected);
      }
      expect(state()!.index, 3);
      voice.finish();
      await Future<void>.delayed(Duration.zero);
      expect(state(), isNull);
    });

    test('pause stops the voice; reading on starts that piece again',
        () async {
      await reader.start(message, body);
      voice.finish();
      await Future<void>.delayed(Duration.zero);
      reader.pause();
      expect(voice.stops, 1);
      expect(state()!.playing, isFalse);

      // A finish arriving from the piece that was stopped is not taken for
      // the next one.
      voice.finish();
      await Future<void>.delayed(Duration.zero);
      expect(state()!.index, 1);

      await reader.resume();
      expect(voice.said.last.text, 'First.');
      expect(state()!.playing, isTrue);
    });

    test('forward and back a paragraph, and the speed', () async {
      await reader.start(message, body);
      await reader.next();
      await reader.next();
      expect(voice.said.last.text, 'Second.');
      await reader.previous();
      expect(voice.said.last.text, 'First.');
      await reader.setRate(1.5);
      expect(voice.said.last.text, 'First.');
      expect(voice.said.last.rate, 1.5);
    });

    test('with no Hebrew voice, the Hebrew is passed over and said so',
        () async {
      voice = FakeSpeechEngine(languages: const {englishVoice});
      c = ProviderContainer(
        overrides: [speechEngineProvider.overrideWithValue(voice)],
      );
      addTearDown(c.dispose);
      reader = c.read(readAloudProvider.notifier);

      await reader.start(
        message,
        const MailBody(text: 'שלום רב\n\nThe meeting is at ten.'),
      );
      expect(state()!.missingVoice, hebrewVoice);
      expect(state()!.pieces.map((p) => p.text),
          ['Plan', 'The meeting is at ten.']);
    });

    test('a phone with no voice says so instead of reading', () async {
      voice.unavailable = true;
      await reader.start(message, body);
      expect(state()!.unavailable, isTrue);
      expect(state()!.playing, isFalse);
    });

    test('stops when its message goes, and only then', () async {
      await reader.start(message, body);
      reader.stopFor('a:INBOX#2');
      expect(state(), isNotNull);
      reader.stopFor(message.id);
      expect(state(), isNull);
    });
  });
}
