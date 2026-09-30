# Noctalia Plugins

Custom plugins repository for [Noctalia](https://noctalia.dev).

## Included Plugins

- **Home Assistant & Music Assistant** (`bjesus/ha-ma`): Monitor and control entities, brightness, scenes, and media players from the bar, panels, and control center. Supports Music Assistant search, playback, and speaker grouping. Based on `pozzoo/hassio` with significant extensions.
- **Tailscale Exit Nodes** (`bjesus/tailscale-exit-nodes`): Bar status indicator, quick connect toggle, and exit node switcher panel.
- **Waybar Custom Commands** (`bjesus/waybar-custom`): Run custom scripts and commands in the Noctalia bar with full Waybar custom module compatibility ([waybar-custom(5)](https://man.archlinux.org/man/waybar-custom.5.en)). Supports polling, continuous streaming, JSON/text formats, tooltips, format icons, HTML entity decoding, and click/scroll actions.

## Adding this source to Noctalia

To install and use plugins from this repository, add it as a git source:

```sh
noctalia msg plugins source add bjesus git https://github.com/bjesus/noctalia-plugins
```

Then enable whichever plugin you want:

```sh
noctalia msg plugins enable bjesus/tailscale-exit-nodes
noctalia msg plugins enable bjesus/ha-ma
noctalia msg plugins enable bjesus/waybar-custom
```

To update plugins from this source:

```sh
noctalia msg plugins update bjesus
```
