# Contributing

Bug reports, printer-compatibility notes and pull requests are welcome.

## Before you open a pull request

```bash
flutter analyze lib test
flutter test
python3 -c 'import ast; ast.parse(open("orca-plugin/printer_hub.py").read())'
```

- UI changes follow [docs/designs/ui-style.md](docs/designs/ui-style.md): tokens `R` (radius), `T` (type), `M` (motion) and `C` (colour) in `lib/ui.dart`, and `StateView` for empty and error states.
- Keep the app's `/hub/*` API (used by the Orca plugin) backwards compatible.
- Commit messages: a short summary line in plain English.

## Releasing (maintainers)

1. Bump `version:` in `pubspec.yaml` and `kAppVersion` in `lib/update.dart`.
2. Add the release notes at the top of `kWhatsNew` in `lib/whats_new.dart`. The app shows them after an update.
3. `python3 tool/changelog.py` to regenerate `CHANGELOG.md` from those notes.
4. If the setup steps changed: `python3 tool/setup_pdf.py` to rebuild `docs/Printer-Hub-Setup.pdf`.
5. Commit, tag `vX.Y.Z`, push the tag. The workflow builds the app, the bridge binaries and the Docker image.
6. `gh release upload vX.Y.Z orca-plugin/printer_hub.py`
