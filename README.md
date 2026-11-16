# Beeper Native

An unofficial native macOS client (SwiftUI) for Beeper. It talks to the local [Beeper Desktop API](https://developers.beeper.com/desktop-api), so Beeper Desktop has to be running in the background.

This project is not affiliated with or endorsed by Beeper or Automattic. "Beeper" is their trademark and is used here only to say what the app connects to.

It is an early version that I use myself. Beeper recommends the Desktop API for personal use only, so please keep it that way.

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 6)
- Beeper Desktop with the Desktop API enabled

## Setup

1. In Beeper Desktop open Settings → Integrations, enable the Desktop API and add an approved connection to get an access token.
2. `./make-app.sh`, then open `build/Beeper Native.app` and paste the token.

`swift run` works too, but without notifications. `BEEPER_TOKEN` in the environment skips the sign-in form.

## Layout

- `Sources/BeeperKit` - the API client, Foundation only.
- `Sources/BeeperNative` - the app.

## Tests

`swift test` runs the offline tests. With `BEEPER_TOKEN` set it also reads from the running Beeper. `BEEPER_SELF_TEST=1` on top of that sends, edits and deletes test messages in your "Note to self" chat.

## License

[MIT](LICENSE)
