# Options Mode

## Current State

- `customize-mode` enters a read-only `options-mode` pane consumer.
- The mode renders effective server, session, window, and pane options for the
  target pane and marks inherited rows explicitly.
- `-F` and `-f` may use `#{option_name}`, `#{option_value}`,
  `#{option_scope}`, `#{option_unit}`, `#{option_is_global}`, and
  `#{option_inherited}`.
- `options-mode` and `options-mode-vi` currently cover navigation, fold/unfold,
  and inherited-row toggling.

## Future Intent

- Port the edit, unset, and reset actions from `window-customize.c`.
- Add key-table browsing so the mode covers binding customization as well as
  option browsing.
