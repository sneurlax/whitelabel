import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture.dart';
import '../support/process.dart';

void main() {
  test(
    'directory copies reject named pipes without blocking',
    () async {
      final f = Fixture();
      addTearDown(f.dispose);
      Directory(p.join(f.sources.path, 'assets')).createSync();
      expect(
        Process.runSync('mkfifo', [
          p.join(f.sources.path, 'assets/pipe'),
        ]).exitCode,
        0,
      );
      final manifest = f.input(
        'brand.json',
        jsonEncode(
          f.data(
            files: [
              {'source': 'assets', 'destination': 'copied', 'mode': 'copy'},
            ],
          ),
        ),
      );
      final script = File(p.join(f.temp.path, 'copy.dart'))
        ..writeAsStringSync('''
import 'package:whitelabel/whitelabel.dart';
void main(List<String> args) {
  Configurator(projectRoot: args[1], manifest: BrandManifest.load(args[0])).plan();
}
''');
      final result = await runDart(script, [manifest.path, f.project.path]);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Only regular files and directories may be copied'),
      );
      expect(f.project.listSync(), isEmpty);
    },
    skip: Platform.isWindows ? 'POSIX named pipes' : false,
  );
}
