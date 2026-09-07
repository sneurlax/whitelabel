import 'dart:convert';

import 'manifest.dart';

/// Renders `{{context:variable}}` tokens in one pass. Substituted values are
/// not scanned for tokens again. Braces that do not open a token, as in
/// `${{ github.sha }}`, pass through verbatim.
String renderTemplate(String template, Map<String, Object?> variables) {
  final tokenStart = RegExp(r'\s*[A-Za-z_][A-Za-z0-9_]*:');
  final buffer = StringBuffer();
  var offset = 0;
  while (offset < template.length) {
    final start = template.indexOf('{{', offset);
    if (start < 0) {
      buffer.write(template.substring(offset));
      break;
    }
    buffer.write(template.substring(offset, start));
    if (tokenStart.matchAsPrefix(template, start + 2) == null) {
      buffer.write('{{');
      offset = start + 2;
      continue;
    }
    final end = template.indexOf('}}', start + 2);
    if (end < 0) throw const FormatException('Unclosed template token');
    final token = template.substring(start + 2, end).trim();
    final match = RegExp(
      r'^([a-z]+):([A-Za-z_][A-Za-z0-9_.]*)$',
    ).firstMatch(token);
    if (match == null) throw FormatException('Invalid template token: $token');
    Object? value = variables;
    for (final segment in match.group(2)!.split('.')) {
      if (value is! Map<String, Object?> || !value.containsKey(segment)) {
        throw FormatException('Unknown template variable: ${match.group(2)}');
      }
      value = value[segment];
    }
    buffer.write(encodeTemplateValue(match.group(1)!, value));
    offset = end + 2;
  }
  return buffer.toString();
}

/// `dart`, `json`, and `yaml` yield complete literals, quotes included. `xml`
/// escapes attribute or text content. `text` emits the string verbatim.
String encodeTemplateValue(String context, Object? value) {
  switch (context) {
    case 'dart':
      return jsonEncode(freezeValue(value))
          .replaceAll(r'$', r'\$')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');
    case 'json':
    case 'yaml':
      return jsonEncode(freezeValue(value));
    case 'xml':
      final text = _string(value, context);
      if (text.runes.any(
        (rune) =>
            !(rune == 9 ||
                rune == 10 ||
                rune == 13 ||
                rune >= 0x20 && rune <= 0xd7ff ||
                rune >= 0xe000 && rune <= 0xfffd ||
                rune >= 0x10000 && rune <= 0x10ffff),
      )) {
        throw const FormatException('Invalid XML character');
      }
      return text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&apos;')
          .replaceAll('\t', '&#9;')
          .replaceAll('\n', '&#10;')
          .replaceAll('\r', '&#13;');
    case 'text':
      return _string(value, context);
    default:
      throw FormatException('Unknown template context: $context');
  }
}

String _string(Object? value, String context) {
  if (value is! String) {
    throw FormatException('$context requires a string');
  }
  return value;
}
