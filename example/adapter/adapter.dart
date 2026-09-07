import 'dart:convert';

import 'package:whitelabel/whitelabel.dart';

/// Validates the notes app's own settings, then plans through the engine.
ConfigurationPlan planNotes({
  required String projectRoot,
  required BrandManifest manifest,
  bool overwrite = false,
}) {
  final variables = manifest.variables;
  if (variables.keys.toSet().difference({
    'name',
    'service_url',
    'features',
  }).isNotEmpty) {
    throw const FormatException('Unknown notes setting');
  }
  final name = variables['name'];
  final service = variables['service_url'];
  final features = variables['features'];
  if (name is! String || name.trim().isEmpty || service is! String) {
    throw const FormatException('Supply a name and service_url');
  }
  final uri = Uri.tryParse(service);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('service_url must be an HTTPS endpoint');
  }
  if (features is! List ||
      features.any((feature) => feature != 'export') ||
      features.toSet().length != features.length) {
    throw const FormatException('Supported features: export (no duplicates)');
  }
  final exportEnabled = features.contains('export');
  return Configurator(projectRoot: projectRoot, manifest: manifest).plan(
    overwrite: overwrite,
    generatedFiles: [
      GeneratedFile(
        'lib/settings.g.dart',
        utf8.encode(
          'const appName = ${encodeTemplateValue('dart', name)};\n'
          'const serviceUrl = ${encodeTemplateValue('dart', service)};\n'
          'const exportEnabled = $exportEnabled;\n',
        ),
      ),
      if (exportEnabled)
        GeneratedFile(
          'assets/export.txt',
          utf8.encode('Export is available.\n'),
        ),
    ],
  );
}
