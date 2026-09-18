# Runalyzer

A bar widget for [Omarchy](https://omarchy.org) that shows your recent Strava
running activities, weekly trends, and yearly totals — right in your status
bar.

![Runalyzer popup showing recent runs and weekly/yearly stats](assets/screenshot.jpg)

**Latest release:** [v0.3.2](https://github.com/grunkan/runalyzer/releases/tag/v0.3.2) — see all [releases](https://github.com/grunkan/runalyzer/releases) for the changelog.

## Features

- Your last 5 runs — name, date, time, distance, duration, pace, elevation
  gain, and average heart rate. Click a run to open it on Strava; hover for
  a "View on Strava" tooltip.
- **Last 7 days** summary: runs, km, time, elevation gain.
- **Last 6 weeks** trend: runs, km, average km/week.
- **This year** totals: runs, km, average km/week.
- Toggle any of the four sections on/off from the settings panel.
- Configurable auto-refresh interval (5–120 minutes, default 15).

## Requirements

- [Omarchy](https://omarchy.org) (`omarchy-shell`)
- Python 3 — standard library only, no `pip install` needed
- A Strava account and your own free Strava API application (see Setup below)

## Installation

Via the Omarchy plugin CLI:

```sh
omarchy plugin add https://github.com/grunkan/runalyzer.git --enable
```

Or manually:

```sh
git clone https://github.com/grunkan/runalyzer.git ~/.config/omarchy/plugins/grunkan.runalyzer
omarchy-shell shell rescanPlugins
omarchy plugin enable grunkan.runalyzer
```

## Setup: connecting your Strava account

Strava requires every app to use its own API credentials, so you'll need to
create a small (free) API application for your own account:

1. Go to [strava.com/settings/api](https://www.strava.com/settings/api) and
   create an application.
   - Set **Authorization Callback Domain** to `localhost`.
2. Copy the **Client ID** and **Client Secret** it gives you.
3. Click the Runalyzer icon in your bar, paste the Client ID and Client
   Secret into the fields shown, and click **Connect**.
4. Your browser opens Strava's login/authorize page — approve access.
5. Runalyzer syncs automatically from then on.

Your credentials and tokens are stored locally in
`~/.local/state/omarchy/strava/auth.json` (file permissions `600`) and are
only ever sent directly to Strava's own API — nowhere else.

## Configuration

Click the gear icon in the popup to:

- Toggle which of the four sections (Last 7 days / Last 6 weeks / This year /
  Last 5 activities) are shown.
- Set the auto-refresh interval in minutes.

## License

MIT — see [LICENSE](LICENSE).
