# Runalyzer

A bar widget for [Omarchy](https://omarchy.org) that shows your recent Strava
running activities, weekly trends, and yearly totals — right in your status
bar.

![Runalyzer popup showing recent runs and weekly/yearly stats](assets/screenshot.jpg)

**Latest release:** [v0.4.2](https://github.com/grunkan/runalyzer/releases/tag/v0.4.2) — see all [releases](https://github.com/grunkan/runalyzer/releases) for the changelog.

## Features

- Your latest runs — name, date, time, distance, duration, pace, elevation
  gain, and average heart rate. Click a run to open it on Strava; hover for
  a "View on Strava" tooltip.
- **Last 7 days** summary: runs, km, time, elevation gain.
- **Weekly trend** over 2–12 weeks: runs, km, average km/week, a bar chart of
  kilometres per week, and how the period compares to the one before it.
- **This year** totals: runs, km, average km/week.
- Your current streak of consecutive weeks with at least one run.
- Toggle any of the four sections on/off, and choose how many weeks the trend
  covers and how many activities the list shows.

All time windows are rolling: "last 7 days" is today plus the six days before
it, and a trend of N weeks is today plus the preceding N×7−1 days. Changing a
setting recomputes everything immediately — no waiting for the next sync.

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
   - Note: the application requires a **Website** and an **Application
     Icon**. Use `https://github.com/grunkan/runalyzer` as the website, and
     upload [`assets/icon.png`](assets/icon.png) from this repo as the icon.
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

- Toggle which of the four sections (Last 7 days / Weekly trend / This year /
  Recent activities) are shown.
- Set how many weeks the trend covers (2–12, default 6).
- Set how many activities the list shows (3–10, default 5).
- Set the auto-refresh interval in minutes (5–60, default 15).

Settings are stored per widget in `~/.config/omarchy/shell.json` and survive
reinstalling the plugin.

## License

MIT — see [LICENSE](LICENSE).
