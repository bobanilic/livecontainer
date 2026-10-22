# PiP-only research: LiveContainer R and system Picture-in-Picture

Status: research and diagnostic branch. The signed LiveContainer R installation and Siri media router are unchanged.

## Findings from source and comparable open-source projects

1. Upstream LiveContainer issue #942 (Oct 28 2025) documents PiP contents stopping when leaving the host for the iOS Home Screen, while Spotify works. This matches our iPhone Bridge observation and does not prove a unique bug in the bridge. https://github.com/LiveContainer/LiveContainer/issues/942
2. Current LiveContainer R PiPManager.m uses AVPictureInPictureVideoCallViewController and an activeVideoCallSourceView anchored to its multitask window. It calls startPictureInPicture but does not deliver real camera/remote video and previously reported no start/stop lifecycle telemetry. The host's AVAudioSession is configured for Playback in PiPManager.init; this is not the same as playing an audio loop. The user has rejected all audio-loop background services, so no silent or audible playback experiments should be revived.
3. uakihir0/UIPiPDemo displays a **changing clock** using AVSampleBufferDisplayLayer; a UIView is drawn to a pixel image, packaged into CMSampleBuffer, then enqueued for native PiP. It reports that PiP continues to show the clock when the app enters the background. Its Info.plist declares UIBackgroundModes/audio and its ViewController configures AVAudioSession.playback; this is **not** evidence that every app can run an invisible background WebSocket. https://github.com/uakihir0/UIPiPDemo
4. videosdk-live/videosdk-ios-pip-mode-example is a real video-call PiP sample. It maps genuine WebRTC RTCVideoTrack frames to a PiP view controller and observes AVPictureInPictureControllerDelegate. It does not demonstrate hidden headless background execution. https://github.com/videosdk-live/videosdk-ios-pip-mode-example
5. Apple documents the video-call content-source API, that PiP requires actual visual content, and that AVPictureInPictureController can be possible, active, or suspended. https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls
6. Apple provides AVPictureInPictureSampleBufferPlaybackDelegate including pictureInPictureControllerShouldProhibitBackgroundAudioPlayback. This offers an explicit way to prohibit background **audio** in a sample-buffer player, but it does not provide new process entitlements. https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate

## Implementation direction — no fabricated media service

First, validate the **existing** host PiP controller with this diagnostic build. Record:
- start-requested, controller-created, start-invoked, will-start, did-start, will-stop, did-stop, failed-to-start
- UIKit host application lifecycle
- isPictureInPicturePossible, isPictureInPictureActive, isPictureInPictureSuspended, isPictureInPictureSupported
- WebSocket state independently via Cloudflare /iphone/statusz (external validation)

Only if evidence shows the existing PiP controller fails or suspends at the Home Screen should we introduce an **optional real status view** behind AVSampleBufferDisplayLayer. The status view would display truthful current device/relay state; no silent audio, no fake video call, and no arbitrary video decoding. It must be user visible and initiated. SampleBufferPlaybackDelegate should prohibit background audio, and no AVAudioEngine instances should exist. Test a low update rate (up to 1 frame per second only when status changes), memory pressure and battery impact. Do not assume rendering a visible frame gives continuous WebSocket execution.

An explicit per-app “Allow in background” toggle is only appropriate if the underlying Apple-managed PiP session actually stays present on the Home Screen. The toggle should state its limits instead of promising unrestricted background processing.

## Acceptance criteria

- PiP becomes a real iOS-level floating window visible on the Home Screen and while ChatGPT is foregrounded.
- After 30 seconds, 3 minutes and 10 minutes, Cloudflare returns deviceOnline=true and a typed device-info round trip succeeds.
- Run the same checks with ChatGPT dictation, screen lock, and normal switch to other apps.
- No background audio playback or generated silent PCM. No developer-service privileges claimed.
- Preserve Siri media router, RAIDO, SideStore, signed LiveContainer app identity and data containers.

If PiP fails due to OS restrictions on non-video apps, document that limitation and switch to on-demand supported iOS automation; do not add a misleading checkbox.
