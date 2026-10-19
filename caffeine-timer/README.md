# Caffeine Timer

Keep the computer awake on a timer, with a single Noctalia bar widget.

Works like the built-in **Caffeine** widget, but every click starts or extends a *timed* session: the computer will not sleep until the countdown ends, and then caffeine is switched off automatically.

## Plugin

| Field | Value |
| --- | --- |
| ID | `bjesus/caffeine-timer` |
| Entries | Widget: `caffeine` |

## Usage

1. Add the widget to your bar:

   ```toml
   [widget.caffeine_timer]
   type = "bjesus/caffeine-timer:caffeine"
   ```

2. Click it to cycle through durations. Each click resets the countdown:

   | Click | Session |
   | --- | --- |
   | 1 | 5 minutes |
   | 2 | 10 minutes |
   | 3 | 30 minutes |
   | 4 | 1 hour |
   | 5 | 2 hours |
   | 6 | 5 hours |
   | 7 | 12 hours |
   | 8 | forever (no deadline, shown as ∞) |
   | 9 | cancel — caffeine off |

   The next click after cancelling starts a fresh 5-minute session. While a session runs, the widget shows the coffee glyph in the accent color with the remaining time; when off it is dimmed.

While a session is active the computer will not sleep, the screen saver will not kick in, and the machine will not auto-suspend. Sessions use the shell's own idle inhibitor (`noctalia msg caffeine-enable` / `caffeine-disable`), so the built-in **Caffeine** widget — if you have it on a bar — shows the same state.

The tooltip always shows the current duration, the remaining time, when the session ends, and what the next click will do.

## Settings

Edited under **Settings → Plugins → Caffeine Timer**:

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `right_click_cancels` | bool | `true` | Right-clicking the widget cancels the timer immediately. |
| `middle_click_cancels` | bool | `true` | Middle-clicking the widget cancels the timer immediately. |
| `notify_on_finish` | bool | `true` | Show a notification when the timer ends and caffeine is disabled again. |
| `show_remaining` | bool | `true` | Show the remaining time next to the coffee glyph while a session runs. |

Note: middle-clicking normally opens the widget's settings; this widget claims the middle button for cancelling (you can still reach the settings from **Settings → Plugins**).

## IPC

The widget can also be driven over IPC, which is useful for compositor keybinds:

```sh
noctalia msg plugin bjesus/caffeine-timer:caffeine focused next     # same as a left click
noctalia msg plugin bjesus/caffeine-timer:caffeine focused cancel    # cancel the running session
```

## Notes

- If the compositor does not support idle inhibition (and logind can't either), starting a session shows an error notification and the timer is cancelled rather than pretending to work.
- Cancelling manually (right/middle click, or clicking past *forever*) never sends a notification — you did it yourself.
- The timer is shared by all placements of the widget, so it shows the same countdown on every bar.
