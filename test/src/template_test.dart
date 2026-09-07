import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';
import 'package:yaml/yaml.dart';

void main() {
  const difficult = 'A "quoted" name & <tag> \\ path\n\t\$value 😀';
  test('json and yaml literals round-trip', () {
    final data = {
      'name': difficult,
      'flags': [true, null, 3],
    };
    expect(jsonDecode(encodeTemplateValue('json', data)), data);
    expect(
      loadYaml('value: ${encodeTemplateValue('yaml', data)}')['value'],
      data,
    );
  });
  test('dart literals compile and keep interpolation characters', () async {
    final temp = Directory.systemTemp.createTempSync('whitelabel-literal-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final source = File('${temp.path}/literal.dart')
      ..writeAsStringSync(
        "import 'dart:convert';\nvoid main() { print(jsonEncode(${encodeTemplateValue('dart', {'value': difficult})})); }\n",
      );
    final process = await Process.run(Platform.resolvedExecutable, [
      source.path,
    ], stdoutEncoding: utf8);
    expect(process.exitCode, 0, reason: process.stderr.toString());
    expect(jsonDecode(process.stdout.toString()), {'value': difficult});
  });
  test('xml escapes delimiters and whitespace', () {
    expect(
      encodeTemplateValue('xml', '"<&>\'\n\t\r'),
      '&quot;&lt;&amp;&gt;&apos;&#10;&#9;&#13;',
    );
    expect(() => encodeTemplateValue('xml', '\x00'), throwsFormatException);
  });
  test('substituted values are not rendered again', () {
    expect(
      renderTemplate('{{text:value}}', {'value': '{{text:missing}}'}),
      '{{text:missing}}',
    );
  });
  test('nested lookup distinguishes null from absent values', () {
    expect(
      renderTemplate('{{json:config.value}}', {
        'config': {'value': null},
      }),
      'null',
    );
    expect(
      () => renderTemplate('{{json:config.missing}}', {
        'config': {'value': null},
      }),
      throwsFormatException,
    );
  });
  test('braces that do not open a token pass through verbatim', () {
    const expression = r'${{ github.sha }}';
    expect(renderTemplate(expression, {}), expression);
    expect(
      renderTemplate('$expression {{name}} {{dart:name}}', {'name': 'ok'}),
      '$expression {{name}} "ok"',
    );
  });
  test('whitespace around typed tokens remains supported', () {
    expect(renderTemplate('{{ dart:name }}', {'name': 'ok'}), '"ok"');
    expect(renderTemplate('{{\ntext:name\t}}', {'name': 'ok'}), 'ok');
  });
  for (final template in [
    '{{ unknown:name }}',
    '{{Dart:name}}',
    '{{context_2:name}}',
    '{{unknown:name}}',
    '{{text:missing}}',
    '{{dart:name',
    '{{text:name..field}}',
  ]) {
    test('rejects invalid token $template', () {
      expect(
        () => renderTemplate(template, {'name': 'ok'}),
        throwsFormatException,
      );
    });
  }
  test('text requires a string', () {
    expect(() => encodeTemplateValue('text', 42), throwsFormatException);
  });
}
