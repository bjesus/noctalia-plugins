# Waybar Custom Commands for Noctalia

A Noctalia bar plugin that runs custom shell commands and scripts with 100% Waybar custom module compatibility ([waybar-custom(5)](https://man.archlinux.org/man/waybar-custom.5.en)).

All configuration is done directly within Noctalia (`settings.toml` or Noctalia's Settings UI).

## Features

- **Full Waybar `custom/<name>` specification support**:
  - `exec`: polling or continuous/streaming script execution.
  - `exec_if`: conditional execution gate (skips execution and hides module if exit code ≠ 0).
  - `interval`: polling rate in seconds (supports `0` to `2147483647`). `0` for continuous streaming, or `-1` for startup-only.
  - `restart_interval`: restart delay for continuous scripts if they exit (up to `2147483647` seconds).
  - `return_type`: `"json"` or raw/i3blocks newline-separated format (`text\ntooltip\nclass`).
  - `format`: full placeholder replacement (`{text}`, `{}`, `{icon}`, `{percentage}`, `{alt}`).
  - `format_icons`: percentage arrays or class/alt/text/default dictionaries.
  - `max_length` & `min_length`: UTF-8-aware character truncation and alignment padding (`align`/`justify`).
  - `hide_empty_text`: dynamically hides the widget if the output text is empty.
  - `escape`: XML/HTML markup escaping when needed.
  - `exec_on_event`: automatically re-executes `exec` after click or scroll actions.
  - `tooltip` & `tooltip_format`: customizable tooltips with markup support.
  - Interactivity: `on_click`, `on_click_right`, `on_click_middle`, `on_scroll_up`, `on_scroll_down`, and `on_update`.
  - Signal / IPC: supports manual refresh via `noctalia msg plugin bjesus/waybar-custom:custom <target> refresh`.

---

## Configuration

You can add multiple instances of `bjesus/waybar-custom:custom` to your bar in `~/.local/state/noctalia/settings.toml` or configure them using Noctalia's Settings UI.

### Examples

#### 1. Long-polling JSON module (e.g. Market Quotes / Stocks)
```toml
[widget.market]
type = "bjesus/waybar-custom:custom"
exec = "/usr/local/bin/market-ticker"
interval = 1800
return_type = "json"
format = " {} "
tooltip = true
escape = false
on_click = "true"
```

#### 2. Continuous streaming module (e.g. live status daemon)
```toml
[widget.live_status]
type = "bjesus/waybar-custom:custom"
exec = "/usr/local/bin/status-stream"
interval = 0
return_type = "json"
format = "{icon} {text}"
format_icons = '{"default": "󰍹 "}'
tooltip = true
escape = false
on_click = "pkill -SIGUSR1 -f status-stream"
on_click_right = "pkill -SIGUSR2 -f status-stream"
```

#### 3. Conditional module (e.g. VPN indicator with exec-if)
```toml
[widget.vpn]
type = "bjesus/waybar-custom:custom"
exec = "/usr/local/bin/vpn-status"
exec_if = "test -f /usr/bin/wg"
interval = 60
return_type = "json"
format = "{}  "
tooltip = true
on_click = "sudo wg-quick up wg0"
```

---

## Setting Reference

| Setting | Type | Range / Options | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `exec` | string | Shell command line | `""` | Command or script to execute. |
| `exec_if` | string | Shell command line | `""` | Pre-check condition. Runs `exec` only if exit code is 0. |
| `interval` | int | `0` .. `2147483647` | `0` | Polling interval in seconds (`0` = continuous streaming, `-1` = once). |
| `restart_interval` | int | `0` .. `2147483647` | `0` | Delay before restarting a terminated continuous stream. |
| `return_type` | string | `"json"`, `""` | `""` | `"json"` or `""` (plain / i3blocks). |
| `format` | string | Template string | `"{}"` | Label template (`{}`, `{text}`, `{icon}`, `{alt}`, `{percentage}`). |
| `format_icons` | string | JSON string | `""` | JSON dictionary or array for `{icon}`. |
| `max_length` | int | `0` .. `1000` | `0` | Maximum character length (UTF-8 safe). |
| `min_length` | int | `0` .. `1000` | `0` | Minimum character length. |
| `align` | string | `"left"`, `"center"`, `"right"` | `"left"` | Alignment for padding. |
| `hide_empty_text`| bool | `true`, `false` | `false` | Hides widget when text is empty. |
| `escape` | bool | `true`, `false` | `false` | Escapes XML entities in output. |
| `exec_on_event` | bool | `true`, `false` | `true` | Re-executes `exec` after click or scroll events. |
| `tooltip` | bool | `true`, `false` | `true` | Displays tooltip on hover. |
| `tooltip_format` | string | Template string | `""` | Custom format template for tooltip. |
| `on_click` | string | Shell command line | `""` | Command executed on left click. |
| `on_click_right` | string | Shell command line | `""` | Command executed on right click. |
| `on_click_middle`| string | Shell command line | `""` | Command executed on middle click. |
| `on_scroll_up` | string | Shell command line | `""` | Command executed on scroll up. |
| `on_scroll_down` | string | Shell command line | `""` | Command executed on scroll down. |
| `on_update` | string | Shell command line | `""` | Command executed on every output update. |
