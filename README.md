# SipAwake

Keep your Mac awake with the lid closed for a timed session while using Low Power Mode and a dimmer display.

## Build and run

You need macOS 13 or later and Xcode or the Xcode Command Line Tools with Swift 5.9 or later.

```sh
git clone https://github.com/FujiwaraChoki/sipawake.git
cd sipawake
swift build -c release
.build/release/sipawake --for 2h --dry-run
sudo .build/release/sipawake --for 2h
```

Wait for **SipAwake active** before closing the lid. Keep the Mac ventilated while it runs with the lid closed. Press Ctrl-C in the terminal to end the session early. If you already use a separate sleep override or keep-awake process, stop it before testing normal sleep after SipAwake exits.

## Options

| Option | Behavior |
| --- | --- |
| `--for 2h` | Set the session length using seconds (`s`), minutes (`m`), or hours (`h`). Maximum 24 hours. |
| `--brightness 25` | Cap the built-in display at 25%. A screen that's already dimmer stays dimmer. |
| `--no-dim` | Skip direct brightness changes. |
| `--min-battery 15` | End the session at or below 15% while on battery. SipAwake checks about every five seconds. |
| `--no-extras` | Skip the optional battery-profile settings. |
| `--dry-run` | Preview settings without changes or administrator privileges. |

SipAwake turns on Low Power Mode in the supported battery and charger profiles. Where reported by macOS, the optional savings also enable battery display dimming, disable battery Power Nap, and cap battery display idle time at two minutes. Hardware brightness control is limited to the built-in display and uses a private macOS framework. Support may vary by hardware, macOS version, and login session.

## Sleep and recovery

Closed-lid operation requires the administrator-only, system-wide `pmset disablesleep` switch. It also suppresses other forms of system sleep during the session. The display remains free to sleep. Sleep behavior can vary by Mac model and macOS version.

SipAwake writes a recovery record before each change. On timeout, battery cutoff, Ctrl-C, or a terminal hangup, it restores settings it changed and releases its sleep override last. Settings changed separately during a session are generally preserved. A pre-existing sleep override stays enabled after the session.

A forced kill or abrupt shutdown can interrupt cleanup. If macOS makes the built-in display inaccessible while the lid is closed, brightness may also need a second restoration attempt after reopening. A new session attempts recovery first. You can recover manually with the same executable

```sh
sudo .build/release/sipawake restore
```

If an existing system-wide sleep override was set outside SipAwake and you want to clear it, run `sudo pmset -a disablesleep 0`.

## Tests

```sh
swift test
```

The automated tests exercise the power-profile parser and recovery logic using simulated settings. To verify closed-lid operation on your Mac, start a short session while a foreground task records timestamps. Check for continuous timestamps across the time the lid was closed, then use `pmset -g` and `pmset -g custom` to check the restored power settings.
