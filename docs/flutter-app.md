# Sycophant Flutter Client

A Flutter chat client for sycophant. It ships Android only; iOS support is scaffolded but not built.

The client is a single-screen chat app: text input, send button, scrollable message list. On entry the app opens a persistent server-streaming `ChannelReceive` stream; each send is a unary `ChannelIngest`, and the assistant bubble fills in as `ChannelOutbound` reply events arrive on the receive stream.

**The client's OIDC item has not landed.** The app's sign-in flow is being rebuilt around the operator's person token (a Dex-issued OIDC token presented as the gRPC bearer credential); until that item lands, the e2e drives the app path with grpcurl plus the operator's token, not the Flutter app. The code in `client/` predates the migration: it still uses the removed pairing-code sign-in and its old `adapter_hint`. The sections below describe the target state.

## Prereqs

- macOS (for the Android build chain via Flutter)
- Flutter 3.41+ — `brew install --cask flutter`
- Android command-line tools — `brew install --cask android-commandlinetools`, then symlink/install build-tools 36.0.0 + 28.0.3 + platforms;android-36 into `~/Library/Android/sdk` (run `flutter doctor --android-licenses` if `flutter doctor` complains)
- `protoc` — `brew install protobuf`
- `dart pub global activate protoc_plugin`
- Android phone with USB debugging enabled (Settings → System → Developer Options → USB debugging)
- `adb` — comes with Android SDK platform-tools

## Build

```sh
cd client
flutter pub get
flutter analyze    # should report only cosmetic info from generated code
flutter test       # smoke test only
flutter build apk --debug
```

The APK lands at `client/build/app/outputs/flutter-apk/app-debug.apk` (~150 MB; debug builds are large because of the JIT runtime).

## Sideload to phone

```sh
# Connect phone via USB, accept the "trust this computer" prompt on the
# phone, then verify it's reachable:
adb devices
# expect: <serial>  device

adb install client/build/app/outputs/flutter-apk/app-debug.apk
```

If `adb install` fails with `INSTALL_FAILED_USER_RESTRICTED`, enable "Install via USB" in the phone's Developer Options.

## Reaching the relay

Trust flow:

1. Operator (you) deploys headscale plus the app channel with ACME enabled, as the `sycophant-channel` chart, installed into the provisioned tenant by `syco channel up`:
   ```yaml
   # channel.yaml
   channel:
     name: app
     tenant: hello-world
     kind: app
     loginServer: https://hs.yourdomain.com
     headscale:
       enabled: true
       serverUrl: https://hs.yourdomain.com
       acme:
         enabled: true
         email: you@yourdomain.com
   ```
   ```sh
   syco channel up -f channel.yaml
   ```
   Re-run it after editing the channel values to apply the change.
2. On the phone, join the tailnet: install the official Tailscale Android client (Play Store or `sideload-via-adb` an F-Droid build); set "Use an alternate server" to `https://hs.yourdomain.com`; log in via auth-key minted from headscale.
3. Bind the person to their workspaces with the user command — `syco user up` writes the subject's workspace list and reach RoleBindings; the relay authorizes each request by Kubernetes review from that grant. See the [relay docs](relay.md) for the identity model.
4. Open the sideloaded sycophant app. Fill in server `relay:9090` (the app adapter's MagicDNS hostname), workspace, and the person token. The app presents the token as the gRPC bearer credential; the relay TokenReviews it and authorizes the named workspace per request.

## Chat

The chat path uses the **channel-adapter pattern**: the Flutter app behaves as an external channel for a single end-user. The workspace harness is the sole authority over what gets dispatched to the LLM for that workspace (it reads AGENTS.md and pulls the workspace's tool catalog on every turn); the Flutter app never calls `Turn` directly.

Per chat-screen entry:

1. The app opens a persistent server-streaming `ChannelReceive` RPC naming its workspace, with `adapter_hint: "flutter-app"`. The `adapter_hint` is free-form, untrusted, and log-only — operators use it to grep ChannelReceive registrations in controller logs; it's never used for routing.
2. **The first `ChannelOutbound` event on the response stream is a `ChannelAck` carrying the server-minted `channel_id` (a UUID).** The app stores this id for the rest of the session and echoes it on every subsequent `ChannelIngest`. The id is opaque to the client and valid only within the lifetime of this `ChannelReceive` stream.
3. On user send, the app issues a unary `ChannelIngest` carrying `channel_id` + the user message. The controller validates the channel_id is bound to the caller's verified subject and workspace (PermissionDenied otherwise — preventing cross-workspace routing-key hijack), stamps the user message's `reply_channel = channel_id`, and routes through the workspace's `Subscribe` stream to the harness. The harness runs the agent loop and emits replies via the workspace outbound channel sink, which the controller forwards to the open `ChannelReceive` stream.
4. Subsequent `ChannelOutbound` events are `send_message` variants carrying the agent's reply content.

The `ChannelIngestAck` returns the same `channel_id` plus a `conversation_id`. The conversation_id is the handle the app would use to call `GetConversationHistory` on reconnect to fetch any assistant replies missed while the receive stream was down (the conversation log on the harness side is the durable source of truth; the `ChannelReceive` stream is a push-notification optimization on top). This replay path is not yet wired in the app — the field is captured but unused — but the controller-side primitives are in place.

Every RPC carries the caller's bearer token; the relay authenticates it by TokenReview and authorizes the named workspace by a Kubernetes access review. First message takes ~10–30 s (LLM Job cold start); subsequent messages typically arrive within a few hundred ms.

## Revocation and re-invite

Revocation is operator-driven and works on the next request: remove the person's reach RoleBinding (re-run `syco user up` without the workspace), and the relay's next authorization review fails. The person's token expires on its own clock; there is no denylist.

## iOS (kept-in-mind, not shipped)

The Flutter project is scaffolded for both Android and iOS (`flutter create --platforms=android,ios`). `ios/Runner/Info.plist` already has the `NSAppTransportSecurity` exception for cleartext to `*.ts.net` and `*.ts.local`. Building iOS requires Xcode + an Apple Developer account, and is not done yet.

## Codegen

When `crates/relay-proto/proto/relay/v1/relay.proto` changes, regenerate the Dart stubs:

```sh
cd client && ./scripts/codegen.sh
```

The generated files in `client/lib/src/generated/` are committed (so a fresh clone is buildable without `protoc`); rerun the script and commit the diff when the proto evolves.

## Known limitations

- **Revocation is operator-driven** — re-run the user command without the workspace or handle. No in-app refresh or rotate UX.
- **No multi-conversation support** — single chat thread per device.
- **No offline queue, no push notifications, no background sync** — when the app isn't foregrounded, the gRPC stream dies.
- **`tools` field is unused** — the chat sends only text content; the LLM has access to the workspace's tools server-side (configured in the chart), but the Flutter app doesn't render tool-call confirmation flows.
- **No image content** — `ContentBlock` supports inline images at the proto layer; the Flutter UI doesn't surface them yet.
- **Connection lifecycle is naive** — the channel stays open for the lifetime of the chat screen; backgrounding/foregrounding may need handling for production.
- **OIDC sign-in is not yet implemented** — until the app's OIDC client item lands, the app path is driven by grpcurl plus an operator token in the e2e.
