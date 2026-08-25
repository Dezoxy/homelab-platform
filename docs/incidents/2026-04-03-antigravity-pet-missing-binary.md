# Incident: Python Environment Tools (PET) Failing in Antigravity

**Date:** 2026-04-03
**Severity:** Low
**Status:** Resolved

## Symptom

On every window reload in Antigravity (the IDE), a notification appeared:

> Python Environment Tools (PET) failed after 3 restart attempts. Please reload the window or check the output channel for details.

## Investigation

Initial debugging was hampered because the logs for the running Antigravity IDE are stored under `~/Library/Application Support/Antigravity/logs/`, not `~/Library/Application Support/Code/logs/` (where VS Code stores them). Early attempts were made against the wrong log location.

Once the correct logs were found, the root cause was immediately visible:

```
[error] [pet] Process error: A system error occurred
  (spawn /Users/horvathtoom/.antigravity/extensions/ms-python.python-2026.4.0-universal/python-env-tools/bin/pet ENOENT)
```

The `ms-python.python-2026.4.0-universal` Python extension installed in Antigravity was missing its `python-env-tools/` directory entirely — an incomplete extension installation. PET would attempt to spawn, fail with `ENOENT`, and retry 3 times before giving up.

## Resolution

Copied the compatible PET binary from the VS Code installation into the expected path:

```sh
mkdir -p ~/.antigravity/extensions/ms-python.python-2026.4.0-universal/python-env-tools/bin
cp ~/.vscode/extensions/ms-python.vscode-python-envs-1.26.0-darwin-arm64/python-env-tools/bin/pet \
   ~/.antigravity/extensions/ms-python.python-2026.4.0-universal/python-env-tools/bin/pet
chmod +x ~/.antigravity/extensions/ms-python.python-2026.4.0-universal/python-env-tools/bin/pet
```

The binary (`pet 0.1.0`, darwin-arm64) is compatible with the universal extension on Apple Silicon.

## Notes

- The `python.useEnvironmentsExtension` setting in `~/Library/Application Support/Code/User/settings.json` was changed from `false` to `true` during investigation, but this was in VS Code's config, not Antigravity's, so it had no effect on the actual problem.
- If the Python extension is updated or reinstalled in Antigravity, the `python-env-tools/` directory may be missing again. The proper fix is reinstalling the extension cleanly through the Antigravity marketplace.
