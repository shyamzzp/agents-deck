# agents deck on iPhone and iPad

The deck on a phone or tablet, drawn by the same
[`agents_deck_ui`](../flutter/agents_ui) package as the desk panel and the menu
bar app. Only the way it reaches the service differs.

## How it connects

The menu bar app talks to `agentctl` over the daemon's unix socket. A phone
cannot open a unix socket, so this app uses the **network listener** instead:
`deviceAddr` in `config.json`, `:7341` by default, over HTTPS with the deck's
own CA pinned. That is the same path the desk panel uses, so
`HttpAgentsClient` in the shared package needed no changes.

The loopback dashboard (`127.0.0.1:7340`) is deliberately not reachable from
another device, and this app does not use it.

## Pairing

The device needs the deck's CA, a certificate of its own and the matching key.
`agentctl pair` already writes exactly the JSON the shared `AgentsConfig`
parses:

```sh
agentctl pair ipad --scope act --bundle agents.json
```

Paste the contents of that file into the app's pairing screen. It is stored at
`Documents/agents.json` inside the app's container. **Delete the file on the
Mac afterwards: it holds the device's private key.** Cut a device off with
`agentctl devices revoke ipad`.

Scopes are `view` (look only), `act` (answer prompts) and `admin`.

`docs/phone.md` sets out a stronger scheme: a QR code carrying the listener
address, the CA fingerprint and a one-time code; a key generated in the Secure
Enclave; and a CSR to `POST /v1/pair`, so the private key never touches disk.
The server side of that already exists; `agentctl pair --qr` and the Enclave
work do not. This app takes the bundle route first.

## Building

Both devices need to be on the same network as the Mac, or reach it over a VPN.
Never expose `:7341` to the internet.

```sh
cd clients/mobile
flutter pub get
flutter analyze && flutter test
flutter run -d <device-id>        # flutter devices to list them
```

Signing uses automatic provisioning; set `DEVELOPMENT_TEAM` in
`ios/Runner.xcodeproj` to your own team. On a free Apple account the signed
build must be made through Xcode's account (Xcode > Settings > Accounts), the
app must be reinstalled every 7 days, and `flutter build ipa` will not work:
use `flutter run` or `flutter install`.
