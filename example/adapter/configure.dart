import 'dart:io';

import 'package:args/args.dart';
import 'package:whitelabel/whitelabel.dart';

import 'adapter.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('manifest', mandatory: true)
    ..addOption('project', mandatory: true)
    ..addFlag('apply', negatable: false)
    ..addFlag('overwrite', negatable: false);
  try {
    final args = parser.parse(arguments);
    final plan = planNotes(
      projectRoot: args['project'] as String,
      manifest: BrandManifest.load(args['manifest'] as String),
      overwrite: args['overwrite'] as bool,
    );
    for (final change in plan.changes) {
      stdout.writeln(change.diff);
    }
    if (args['apply'] as bool) plan.apply();
  } catch (error) {
    stderr.writeln('$error\n${parser.usage}');
    exitCode = 1;
  }
}
