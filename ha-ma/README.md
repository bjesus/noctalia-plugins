# Home Assistant & Music Assistant

Monitor and control your Home Assistant entities and Music Assistant playback from the Noctalia bar, panels, and control center.

## Features

- **Bar Widget & Status**: Real-time connection indicator and optional entity counter.
- **Entity Manager Panel**: Control lights, switches, media players, and toggle automations.
- **Music Assistant Panel & Widget**: Search your Music Assistant library (artists, albums, playlists, tracks), manage active playback, volume, and group speakers.
- **Real-time Updates**: Live Server-Sent Events (SSE) connection streaming state changes.
- **Control Center Shortcuts**: Up to 4 customizable quick-toggle entity shortcuts.

## Plugin

| Field | Value |
| --- | --- |
| ID | `bjesus/ha-ma` |
| Entries | Widgets: `status`, `music_status`; Service: `connection`; Shortcuts: `ha_toggle_1`–`4`, `ha_panel`; Panels: `entity_manager`, `music` |

## Requirements

- Running Home Assistant instance
- Long-Lived Access Token (HA Profile → Security)
- Optional: Music Assistant integration in HA for media features

## Usage

1. Open **Settings → Plugins → Home Assistant & Music Assistant** and provide your Home Assistant URL and Access Token.
2. Add the **status** or **music_status** widget to your bar.
3. Open panels via widgets or IPC:
   ```sh
   noctalia msg panel-toggle bjesus/ha-ma:entity_manager
   noctalia msg panel-toggle bjesus/ha-ma:music
   ```

### Media Actions via IPC

Control playback and volume on the active destination speaker (using the same resolution rules: targeting the currently playing speaker if one is active, or falling back to the latest chosen speaker):

```sh
# Toggle play/pause
noctalia msg plugin bjesus/ha-ma:connection all toggle_pause

# Adjust volume (optional step, defaults to 5%)
noctalia msg plugin bjesus/ha-ma:connection all volume_up
noctalia msg plugin bjesus/ha-ma:connection all volume_down
noctalia msg plugin bjesus/ha-ma:connection all volume_up 0.10

# Toggle mute
noctalia msg plugin bjesus/ha-ma:connection all volume_mute

# Track controls
noctalia msg plugin bjesus/ha-ma:connection all next
noctalia msg plugin bjesus/ha-ma:connection all previous

# Select target speaker
noctalia msg plugin bjesus/ha-ma:connection all select_speaker "Tandberg"
```

You can bind these commands to keyboard shortcuts (e.g. `XF86AudioPlay`, `XF86AudioRaiseVolume`, `XF86AudioLowerVolume`) in your compositor configuration (Sway, Hyprland, Niri, etc.).

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `ha_url` | `string` | `""` | Base URL of your Home Assistant instance |
| `ha_token` | `string` | `""` | Long-lived access token |
| `shortcut_entity_1`–`4` | `string` | `""` | Entity IDs assigned to quick-toggle tiles |
| `show_entity_count` | `bool` | `false` | Show count of monitored entities in the status bar widget |
| `music_format` | `string` | `"{title} - {artist}"` | Now playing format string for the bar widget. Supports tokens `{title}`, `{artist}`, `{album}`, `{speaker}` and per-field max length limits, e.g. `{title:20} - {artist}` |
| `music_max_length` | `int` | `0` | Maximum character length for the total widget label (`0` for unlimited) |
| `music_target_speaker` | `string` | `""` | Entity ID of media player to monitor (or blank to auto-detect) |

## Credits & License

Based on the [Home Assistant plugin](https://github.com/noctalia-dev/community-plugins/tree/main/hassio) (`pozzoo/hassio`) by Pozzoo, licensed under the MIT License. Extended with Music Assistant library browsing, playback search, speaker grouping, and album art support.
