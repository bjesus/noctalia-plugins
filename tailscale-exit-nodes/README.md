# Tailscale Exit Nodes

Clean, simple Tailscale connection toggle and exit node picker for Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `bjesus/tailscale-exit-nodes` |
| Entries | Widget: `status`; Service: `backend`; Panel: `panel` |

## Requirements

- `tailscale` CLI installed and authenticated.
- Operator permissions for your user (e.g. `tailscale up --operator=$USER` or passwordless sudo).

## Usage

1. Add the **status** widget to your bar to show connection state and the currently active exit node. Click to toggle the panel.
2. In the panel:
   - Toggle the main switch to connect or disconnect from Tailscale.
   - Click any available exit node in the list to route your traffic through it.
   - Click the checkmark on the active exit node to disconnect from it.
