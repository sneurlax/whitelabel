# whitelabel

Manifest-driven branding for Dart and Flutter projects. A manifest names a
brand, its variables, and the files to render or copy into a project. The
tool plans every output, then applies the plan with ownership tracking and
rollback.

```sh
dart pub get
dart run bin/whitelabel.dart plan -m example/dart_app/brand.yaml -p <project> --diff
dart run bin/whitelabel.dart configure -m example/dart_app/brand.yaml -p <project>
dart run bin/whitelabel.dart recover -p <project>
```

Templates substitute `{{context:variable}}` tokens, where the context is one
of `dart`, `json`, `yaml`, `xml`, or `text`. See `example/` for manifests,
templates, and an adapter that supplies generated files through the Dart API.

```sh
dart analyze --fatal-infos
dart test
dart run tool/verify_examples.dart [--flutter [--build]]
```

Copy entries preserve ordinary POSIX file permissions, including executable and
private-file bits; Windows uses its normal file permissions. File permission-only
changes appear in plans, and manual file permission edits require `--overwrite`.
Existing template outputs retain their permissions. Transaction staging is
owner-only on POSIX, including backups of files protected by a private parent.

Directory copies include empty directories and preserve ordinary POSIX directory
permissions when creating destinations. Existing destination directories must
have matching permissions; adjust them explicitly if needed. `--overwrite` never
changes an existing directory's permissions. Copied directories remain after
obsolete owned files are pruned, just like implicit parent directories. Plans
expose copied directories in `directories`, separately from file changes.
Output paths must use consistent directory casing, including shared parents.

The verifier accepts `--reproducible`, `--aot`, and `--report <path>` in addition
to its Flutter options. Reports are created exclusively after verification;
existing files are never replaced. If writing a report fails, a partial report
may remain for inspection.
