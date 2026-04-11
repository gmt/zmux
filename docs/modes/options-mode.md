# Options Mode

## Current State

- `customize-mode` enters an `options-mode` pane consumer.
- The mode renders effective server, session, window, and pane options for the
  target pane and marks inherited rows explicitly.
- `-F` and `-f` may use `#{option_name}`, `#{option_value}`,
  `#{option_scope}`, `#{option_unit}`, `#{option_is_global}`, and
  `#{option_inherited}`.
- `options-mode` and `options-mode-vi` currently cover navigation, fold/unfold,
  inherited-row toggling, and prompt-driven unset/reset for option rows.

## Future Intent

- Add the missing key-table browsing and editing path so customize-mode covers
  binding customization as well as option browsing.
- Widen the preview side toward tmux's richer customize-mode presentation once
  there is a real key-binding consumer to show.
