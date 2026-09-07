# whitelabel

Manifest-driven branding for Dart and Flutter projects. A manifest names a
brand, its variables, and the files to render or copy into a project. The
tool plans every output, then applies the plan with ownership tracking and
rollback.

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
