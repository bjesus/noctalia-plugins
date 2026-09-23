# Noctalia Plugins

Custom plugins repository for [Noctalia](https://noctalia.dev).

## Included Plugins

- **Home Assistant** (`pozzoo/hassio`): Monitor and control entities, brightness, scenes, and media players from the bar, panels, and control center. Supports Music Assistant search and playback.
- **Tailscale** (`bjesus/tailscale`): Bar status indicator, quick connect toggle, and exit node switcher panel.

## Adding this source to Noctalia

To install and use plugins from this repository, add it as a git source:

```sh
noctalia msg plugins source add bjesus git https://github.com/bjesus/noctalia-plugins
```

Then enable whichever plugin you want:

```sh
noctalia msg plugins enable bjesus/tailscale
noctalia msg plugins enable pozzoo/hassio
```

To update plugins from this source:

```sh
noctalia msg plugins update bjesus
```
