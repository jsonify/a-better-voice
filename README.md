# A Better Voice

A small iOS, iPadOS and macOS app: drop in a voice recording and get a cleaner, clearer, evenly loud version back.
Everything runs on the device. Nothing is uploaded.

## What it does

Drop a file (or choose one, or use **Open with / Share → A Better Voice** from Files, Finder or Voice Memos) and
the app runs this chain on it:

1. **Rumble filter**: removes handling noise, wind and plosive thumps below 80 Hz.
2. **Noise reduction**: learns the hiss, hum and room tone from the pauses between words and removes it, frequency
   by frequency, without the warbly "underwater" sound of cruder noise removal.
3. **Clarity EQ**: less mud around 250 Hz, more presence at 4 kHz and air at 10 kHz.
4. **De-esser**: turns down harsh "s" and "sh" sounds only while they happen.
5. **Leveling**: a gentle compressor so quiet and loud passages end up closer together.
6. **Loudness normalization**: brings the result to a standard loudness (−16 LUFS for podcasts by default; −14, −18
   and −23 are one tap away), measured to ITU-R BS.1770 / EBU R128.
7. **Peak limiter**: keeps peaks under −1.5 dBFS so nothing clips, even after AAC encoding.

Optionally, switch on **AI voice isolation** to also remove changing background sounds (traffic, keyboards, other
people), music and room echo. It uses Apple's on-device machine-learning voice isolation, the same technology as the
"Voice Isolation" microphone mode, running on the Neural Engine. There's no account, no per-use cost, and nothing
leaves the device. **Isolation strength** blends some of the original back in for a more natural sound. Needs
iOS 17 / macOS 14 (this app's minimum); the switch is greyed out on any device without it.

Pick **Light**, **Balanced** or **Strong**, or open **Fine-tune** to set each stage. The result updates a moment after
each change. Switch between **Original** and **Enhanced** while it plays to compare at the same spot. Save as M4A
(AAC) or 24-bit WAV, or share it straight from the app.

Reads anything Core Audio can decode: M4A/AAC, ALAC, WAV, AIFF, CAF, MP3, FLAC and more. Stereo files are mixed to
mono for processing (voice is mono) and saved with the same channel count.

## Project layout

| Path | What |
| --- | --- |
| `Packages/VoiceEnhancerCore` | The audio engine: a Swift package with no UI, plus unit tests and a `voice-enhance` command-line tool |
| `App/Shared` | The SwiftUI app, shared by the iOS and macOS targets |
| `App/Support` | Info.plists and the macOS sandbox entitlements |
| `App/Resources` | App icon and accent colour |
| `project.yml` | XcodeGen spec that generates `ABetterVoice.xcodeproj` |

## Building

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open ABetterVoice.xcodeproj
```

- **Mac:** choose the `ABetterVoice-macOS` scheme and press ⌘R. It runs signed to run locally, no developer account
  needed.
- **iPhone / iPad:** choose the `ABetterVoice-iOS` scheme, select your team under *Signing & Capabilities* (or set
  `DEVELOPMENT_TEAM` in `project.yml`), pick a simulator or your device and press ⌘R. You may also want to change the
  bundle identifier (`app.abettervoice.ABetterVoice`) to one under your own domain.

Both schemes run the Release configuration: the engine is pure Swift and is far slower unoptimized.

Re-run `xcodegen generate` after adding or removing files; the `.xcodeproj` is not checked in.

### Tests and the command-line tool

```sh
cd Packages/VoiceEnhancerCore
swift test
swift run -c release voice-enhance [--ai] input.m4a output.m4a [light|balanced|strong] [target LUFS]
```

The command-line tool prints the loudness before and after, and is handy for batch work.

CI (`.github/workflows/build.yml`) runs the tests, the command-line tool, and builds both apps with warnings as
errors on every pull request.
