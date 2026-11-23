# MyBlock

An iPhone app for practicing race-like block starts alone: it calls "On your marks" and "Set",
fires the gun after a random hold, records the start, and grades the set position and block
clearance from the video.

Native SwiftUI app. Pose detection uses Apple Vision on the device, so no internet is needed.

## Run it on an iPhone

1. Open `MyBlock.xcodeproj` in Xcode (16 or newer).
2. Select the **MyBlock** target → **Signing & Capabilities** → choose your Apple ID as the **Team**.
   If Xcode says the bundle ID is taken, change `com.wthoman.myblock` to something unique.
3. On the iPhone turn on **Settings → Privacy & Security → Developer Mode**, then plug it in.
4. Pick the phone as the run destination and press **Run (⌘R)**.
   The first time, trust your Apple ID on the phone under **Settings → General → VPN & Device Management**.

With a free Apple ID the install expires after 7 days; run it again from Xcode to renew.
For TestFlight (paid Apple Developer account): **Product → Archive**, then **Distribute App**.

The Simulator shows every screen, but recording needs a real camera and pose analysis needs a real
device (Vision's body-pose request doesn't run in the Simulator).

## How a rep works

Home → **Start** → camera screen → **Start** → get-ready countdown (default 15 s, ticks in the last 5 s,
then a tone) → marks tone (two rising notes) → set tone (one note) → random hold (default 1.8–2.8 s
after the set tone) →
gun → records 3 s more → completion chime → Review opens. Everything needed during a rep is audible.
MyBlock uses no voice: every cue is a tone. If the camera fails or a call/backgrounding interrupts
before the gun, MyBlock stops and plays three falling notes. A rep whose gun already fired is kept if the file can be finished.

`StartSequence` is the only thing that drives the start: one task, one phase, scheduled against one
host clock. The gun is scheduled ahead on the audio device. Its time in the video is an estimate:
(scheduled time + reported output latency) − (recording start callback). That's ±0.05 s on the
speaker, ±0.25 s on Bluetooth, and is stored and shown as such. The video has no audio track.

## Where things are

| Path | What it does |
| --- | --- |
| `MyBlock/MyBlockApp.swift` | App entry, first-run intro and screen flow: home → session → review → results |
| `MyBlock/Session/StartSequence.swift` | Start state machine: countdown, commands, hold, gun, auto-stop, cancel/abort, repeated reps |
| `MyBlock/Session/CuePlayer.swift` | Audio cues, scheduled playback, fallbacks, sound test |
| `MyBlock/Models/Rep.swift`, `RepStore.swift` | Saved reps (video, thumbnail, rep.json) and settings persistence |
| `MyBlock/Screens/` | Home + history, session, review, results, settings, onboarding/setup guide, `CameraController` |
| `MyBlock/UI/Theme.swift`, `MyBlock/UI/Components.swift` | Colors, Dynamic Type styles, spacing, buttons |
| `MyBlock/Analysis/Scoring.swift` | Guide angle ranges, cue text and sources. Tune here. |
| `MyBlock/Analysis/Analysis.swift`, `Coaching.swift` | Joint-angle math, grading, main cue and "unable to assess" summaries |
| `MyBlock/Analysis/FrameAnalyzer.swift` | Frame extraction and Apple Vision pose detection |
| `MyBlock/Resources/Audio/` | Cue sounds (see below). Replace a file to change it. |
| `MyBlockTests/` | Unit tests: sequence timing/cancellation, persistence, settings, coaching |

New files placed inside `MyBlock/` or `MyBlockTests/` are picked up by Xcode automatically.
Run tests with ⌘U, or `xcodebuild test -scheme MyBlock -destination 'platform=iOS Simulator,name=iPhone 17'`.

## Design

Swiss / Olympic-poster graphic design built from the style board: white ground, navy type, and
the board's colors used as flat blocks (track red for the one primary action, sun yellow for the
coaching cue, sky blue as a secondary accent). Sentence case, hairline rules instead of boxed
cards, square corners, no outlines or drop shadows (`Theme.swift`, `Components.swift`). The
vintage feel comes from large flat color fields (the navy poster band on Home, a sky / yellow /
navy page per onboarding step, the yellow cue and cream score band on Results) with a faint print
grain (`PrintGrain` in `Illustrations.swift`). Section markers cycle red, sky, yellow, navy. The track
scenes on Home and in the setup guide are drawn in code (`Illustrations.swift`).

Type: **Archivo Expanded** (Black and ExtraBold) for titles, a wide heavy grotesque with lowercase
chosen to match the Horizon sample on the style board, and **Roboto** for everything else. Both are
bundled from Google Fonts under the SIL Open Font License (`Resources/Fonts/OFL-*.txt`).

## Audio

| File | Use | Source |
| --- | --- | --- |
| `marks.wav`, `set.wav` | Marks (two rising notes) and set (one note) | Generated tones |
| `gun.wav` | Start signal | Original; the source file is clipped (92 samples at full scale), now peaks at −1 dBFS |
| `tone.wav` | Optional electronic start | Generated tone |
| `tick.wav`, `ready.wav`, `complete.wav`, `finished.wav`, `cancel.wav` | Countdown, end of countdown, saved, last rep saved, cancelled | Generated tones |

Still worth replacing: the starting gun with a clean (unclipped) recording. If any file is missing,
a system sound plays instead.

## Privacy

Analysis runs on the phone with Apple Vision. No accounts, uploads or analytics. Recordings are video
only (no microphone permission). Reps are stored in Application Support/Reps, which is excluded from
iCloud and computer backups, so they exist only on this iPhone unless the athlete shares or saves one.
Photos access is add-only and only used when the athlete picks "Save Video" in the share sheet.

## Known limits

- Vision's body pose has no heel or toe points, so the skeleton overlay stops at the ankles.
- Video is recorded at 1080p60 where the camera supports it (otherwise 30 fps), so the clearance frame can still fall between frames.
- The gun time inside the video is an estimate (see above). Times are never shown as reaction times or false-start calls.
- Angles assume a level phone, side-on to the lane.
- Vision body-pose detection doesn't run in the Simulator; analysis needs a real iPhone.
- Shared videos are the original recording, without the skeleton overlay.
