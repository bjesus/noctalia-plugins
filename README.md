# Noctalia Plugins

Custom plugins repository for [Noctalia](https://noctalia.dev).

## Included Plugins

- **Home Assistant & Music Assistant** (`bjesus/ha-ma`): Monitor and control entities, brightness, scenes, and media players from the bar, panels, and control center. Supports Music Assistant search, playback, and speaker grouping. Based on `pozzoo/hassio` with significant extensions.
- **Tailscale Exit Nodes** (`bjesus/tailscale-exit-nodes`): Bar status indicator, quick connect toggle, and exit node switcher panel.

## Adding this source to Noctalia

To install and use plugins from this repository, add it as a git source:

```sh
noctalia msg plugins source add bjesus git https://github.com/bjesus/noctalia-plugins
```

Then enable whichever plugin you want:

```sh
noctalia msg plugins enable bjesus/tailscale-exit-nodes
noctalia msg plugins enable bjesus/ha-ma
```

To update plugins from this source:

```sh
noctalia msg plugins update bjesus
```
