import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:whitelabel/whitelabel.dart';

class Fixture {
  Fixture() {
    project.createSync();
    sources.createSync();
    input('templates/brand.tmpl', 'const name = {{dart:name}};\n');
  }
  final Directory temp = Directory.systemTemp.createTempSync(
    'whitelabel-test-',
  );
  late final Directory project = Directory(p.join(temp.path, 'project'));
  late final Directory sources = Directory(p.join(temp.path, 'sources'));

  void dispose() => temp.deleteSync(recursive: true);

  File input(String path, String contents) =>
      write(sources.path, path, contents);
  File output(String path, String contents) =>
      write(project.path, path, contents);
  static File write(String root, String path, String contents) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  Map<String, Object?> data({
    String brand = 'example',
    String name = 'Example',
    List<Map<String, Object?>>? files,
    List<String> platforms = const [],
  }) => {
    'schema_version': 1,
    'brand': brand,
    'variables': {'name': name},
    'platforms': platforms,
    'files':
        files ??
        [
          {'source': 'templates/brand.tmpl', 'destination': 'lib/brand.g.dart'},
        ],
  };

  BrandManifest manifest({
    String brand = 'example',
    String name = 'Example',
    List<Map<String, Object?>>? files,
    List<String> platforms = const [],
  }) => BrandManifest.parse(
    jsonEncode(
      data(brand: brand, name: name, files: files, platforms: platforms),
    ),
    sourceDirectory: sources.path,
  );

  Configurator configurator({BrandManifest? manifest}) => Configurator(
    projectRoot: project.path,
    manifest: manifest ?? this.manifest(),
  );
  String read(String path) =>
      File(p.join(project.path, path)).readAsStringSync();
}
