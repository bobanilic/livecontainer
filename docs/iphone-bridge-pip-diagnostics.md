# iPhone Bridge PiP diagnostics

This branch starts from `feature/siri-media-router` and preserves that work.

**Diagnostic-only experiment**. It does not enable permanent background execution, alter app launch/signing, or change the original PiP presentation behavior.

In LiveContainer app long-press > Settings, the new **PiP background diagnostics** section reports the latest event and allows copying the last 40 events. To test: open iPhone Bridge as a multitask window, choose Enable PiP from the window title menu, visit Home Screen / ChatGPT, then return and inspect the diagnostic history. Event names include start-requested, controller-created, start-invoked, will-start, did-start, host-entered-background, will-stop, did-stop, and failed-to-start. The history stores no secrets or app content.

If did-start is absent, PiP never activated. If did-stop follows host-entered-background, it was terminated when LiveContainer moved to the background. If did-start persists but the Cloudflare WebSocket is offline, the issue is execution/suspension rather than PiP visual launch.

Do not replace a working LiveContainer with this unsigned build without preserving the app container. iOS may require re-signing with the existing SideStore certificate and identity.
