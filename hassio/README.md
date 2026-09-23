# Home Assistant

Monitor and control your Home Assistant entities from the Noctalia bar and control center.

## Features

- **Bar Widget & Status**: Real-time connection indicator and optional entity counter.
- **Entity Manager Panel**: Control lights, switches, media players, and toggle automations.
- **Music Assistant Panel & Widget**: Search your Music Assistant library (artists, albums, playlists, tracks), manage active playback, volume, and group speakers.
- **Real-time Updates**: Live Server-Sent Events (SSE) connection streaming state changes.
- **Control Center Shortcuts**: Up to 4 customizable quick-toggle entity shortcuts.

## Plugin

| Field | Value |
| --- | --- |
| ID | `pozzoo/hassio` |
| Entries | Widgets: `status`, `music_status`; Service: `connection`; Shortcuts: `ha_toggle_1`–`4`, `ha_panel`; Panels: `entity_manager`, `music` |

## Requirements

- Running Home Assistant instance
- Long-Lived Access Token (HA Profile → Security)
- Optional: Music Assistant integration in HA for media features

## Usage

1. Open **Settings → Plugins → Home Assistant** and provide your Home Assistant URL and Access Token.
2. Add the **status** or **music_status** widget to your bar.
3. Open panels via widgets or IPC:
   ```sh
   noctalia msg panel-toggle pozzoo/hassio:entity_manager
   noctalia msg panel-toggle pozzoo/hassio:music
   ```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `ha_url` | `string` | `""` | Base URL of your Home Assistant instance |
| `ha_token` | `string` | `""` | Long-lived access token |
| `shortcut_entity_1`–`4` | `string` | `""` | Entity IDs assigned to quick-toggle tiles |
| `show_entity_count` | `bool` | `false` | Show count of monitored entities in the status bar widget |
| `music_format` | `string` | `"{title} - {artist}"` | Now playing format string for the bar widget |
| `music_target_speaker` | `string` | `""` | Entity ID of media player to monitor (or blank to auto-detect) |
