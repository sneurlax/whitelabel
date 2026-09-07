import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:whitelabel/whitelabel.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()..addFlag('help', abbr: 'h', negatable: false);
  for (final name in ['plan', 'configure']) {
    parser.addCommand(
      name,
      ArgParser()
        ..addOption('manifest', abbr: 'm', help: 'Consumer manifest YAML file.')
        ..addOption(
          'project',
          abbr: 'p',
          help: 'Existing output project directory.',
        )
        ..addOption(
          'source-root',
          help: 'Input root (default: manifest directory).',
        )
        ..addMultiOption(
          'platforms',
          help: 'Subset of declared platforms; defaults to all.',
        )
        ..addMultiOption(
          'define',
          splitCommas: false,
          help: 'Override a declared variable: name=value (string value).',
        )
        ..addFlag(
          'overwrite',
          negatable: false,
          help: 'Replace or adopt unowned or edited outputs.',
        )
        ..addFlag('json', negatable: false, help: 'Print the plan as JSON.')
        ..addFlag('diff', negatable: false, help: 'Print full diffs.')
        ..addFlag('help', abbr: 'h', negatable: false),
    );
  }
  parser.addCommand(
    'recover',
    ArgParser()
      ..addOption(
        'project',
        abbr: 'p',
        help: 'Project with an interrupted configuration.',
      )
      ..addFlag('help', abbr: 'h', negatable: false),
  );

  void usage([String? command]) {
    stdout.writeln(
      'whitelabel: manifest-driven branding for Dart and Flutter\n'
      '\nUsage:\n'
      '  whitelabel plan -m <manifest.yaml> -p <project> [--diff]\n'
      '  whitelabel configure -m <manifest.yaml> -p <project>\n'
      '  whitelabel recover -p <project>\n'
      '\nplan renders every output without writing to the project.\n'
      'configure applies a fresh plan with backups and ownership tracking.\n'
      'recover rolls back an interrupted configure.\n',
    );
    stdout.writeln(
      command == null ? parser.usage : parser.commands[command]!.usage,
    );
  }

  try {
    final results = parser.parse(arguments);
    final command = results.command;
    if (results['help'] as bool || command == null) {
      usage();
      if (!(results['help'] as bool)) exitCode = 64;
      return;
    }
    if (command['help'] as bool) {
      usage(command.name);
      return;
    }
    if (command.rest.isNotEmpty) {
      throw ArgumentError('Unexpected arguments: ${command.rest.join(' ')}');
    }
    String requiredOption(String name) {
      final value = command[name] as String?;
      if (value == null || value.isEmpty) {
        throw ArgumentError('Missing --$name');
      }
      return value;
    }

    final project = requiredOption('project');
    if (command.name == 'recover') {
      recoverConfiguration(project);
      stdout.writeln('Recovery complete.');
      return;
    }
    final overrides = <String, Object?>{};
    for (final define in command['define'] as List<String>) {
      final index = define.indexOf('=');
      if (index <= 0) throw ArgumentError('--define must be name=value');
      final name = define.substring(0, index);
      if (overrides.containsKey(name)) {
        throw ArgumentError('Duplicate --define: $name');
      }
      overrides[name] = define.substring(index + 1);
    }
    final configurator = Configurator(
      projectRoot: project,
      manifest: BrandManifest.load(requiredOption('manifest')),
      sourceRoot: command['source-root'] as String?,
    );
    final plan = configurator.plan(
      platforms: command.wasParsed('platforms')
          ? command['platforms'] as List<String>
          : null,
      overrides: overrides,
      overwrite: command['overwrite'] as bool,
    );
    if (command['json'] as bool && command['diff'] as bool) {
      throw ArgumentError('Choose --json or --diff');
    }
    if (command.name == 'configure') plan.apply();
    if (command['json'] as bool) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(plan.toJson()));
    } else {
      for (final directory in plan.directories) {
        if (command['diff'] as bool) {
          stdout.write(directory.diff);
        } else {
          stdout.writeln(
            '${directory.action.toUpperCase()} directory ${directory.path}',
          );
        }
      }
      for (final change in plan.changes) {
        if (command['diff'] as bool) {
          stdout.write(change.diff);
        } else {
          stdout.writeln('${change.action.toUpperCase()} ${change.path}');
        }
      }
      stdout.writeln(
        command.name == 'plan'
            ? 'Plan ready. No project files changed.'
            : 'Configuration applied.',
      );
    }
  } on ArgParserException catch (error) {
    stderr.writeln(error.message);
    usage();
    exitCode = 64;
  } on ArgumentError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 64;
  } catch (error) {
    stderr.writeln('error: $error');
    exitCode = 1;
  }
}
