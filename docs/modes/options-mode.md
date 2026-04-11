# Options Mode

## Current State

- `customize-mode` enters an `options-mode` pane consumer.
- The mode renders effective server, session, window, and pane options for the
  target pane and marks inherited rows explicitly.
- The same tree now includes key tables and key bindings, with editable
  `Command`, `Note`, and `Repeat` child rows plus prompt-driven unset/reset for
  bindings.
- `-F` and `-f` may use both option fields like `#{option_name}`,
  `#{option_value}`, `#{option_scope}`, `#{option_unit}`,
  `#{option_is_global}`, and `#{option_inherited}` and key fields like
  `#{key_table}`, `#{key_string}`, `#{key_note}`, `#{key_command}`, and
  `#{key_repeat}`.
- `options-mode` and `options-mode-vi` currently cover navigation, fold/unfold,
  inherited-row toggling, option edits, and key-binding edits within the tree.

## Future Intent

- Widen the preview side toward tmux's richer customize-mode presentation once
  there is a richer customize-mode preview surface to show.
