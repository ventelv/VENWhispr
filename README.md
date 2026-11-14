# VENWhispr

Local, private voice dictation for macOS — a Wispr Flow–style menu bar app.
Hold a key, speak, release: the text is pasted into whatever app has focus.

## Use

| Action | What happens |
|---|---|
| Hold **Right ⌥** | Dictates in English; transcribes and pastes on release |
| Hold **Right ⌘** | Dictates in Romanian |
| Double-tap either key | Locks recording on (hands-free); tap once more to finish |
| **Esc** | Cancels the current recording |

Each key has a fixed language (Hotkeys & Languages in the menu, or Settings → General), which is
~0.8 s faster per dictation than Whisper's auto-detect.

Menu bar icon → Paste Last Dictation, Recent, Microphone, Hotkeys & Languages, Smart Punctuation,
filler-word removal, trailing space, Custom Words, Settings (sounds, mute audio while recording,
keep mic ready, launch at login).

## How it works

- `HotkeyMonitor` watches the right-hand modifier key system-wide.
- `AudioRecorder` records the chosen mic as 16 kHz mono via AVCaptureSession (AVAudioEngine can't
  reliably record from a mic other than the system default). The mic stays on for 2 minutes after
  each dictation so the next one starts instantly, keeping the 0.3 s before the key press.
- `WhisperEngine` runs `whisper-server` (whisper.cpp, Metal GPU, bundled in the app) on `127.0.0.1:8178` with
  `ggml-large-v3-turbo.bin`, keeping the model warm. Nothing leaves the Mac.
- `LivePreview` shows a draft of your words in a card while you dictate, refreshing about twice a
  second with a separate small model (`preview/ggml-base.bin`, `whisper-server` on `127.0.0.1:8181`,
  about 250 MB). It's only a draft: the pasted text still comes from the main model. Turning Live
  Preview off unloads it.
- `DictationLog` writes one line per dictation (mic, level, timings, outcome — never the text).
- `TextCleaner` strips non-speech tags and English fillers (um, uh, er…) and tidies punctuation.
- `PunctuationEngine` runs `llama-server` (llama.cpp, bundled) with Gemma 3 4B on `127.0.0.1:8179` to add
  periods, commas and question marks, only when Whisper's text is a long run-on. Its output is aligned word-by-word back onto Whisper's text, so it
  can only add punctuation/capitals — any word it changes, drops or invents is discarded, and if it
  answers the text instead of punctuating it, Whisper's text is used as-is.
- `AudioDevices` lists microphones via Core Audio and picks the "Automatic" mic: the system default,
  unless that's a Bluetooth headset (AirPods take ~0.5–1.5 s to switch into call mode and cut off
  your first words), in which case a wired mic — USB first, then built-in.
- `OutputMuter` mutes the default output device while recording (music from any app) and restores it,
  touching only what it changed; the saved state survives crashes and is restored at launch.
- `Paster` puts the text on the clipboard, sends ⌘V, then restores your previous clipboard.
- `ModelDownloader` fetches missing models on first launch, resuming interrupted downloads and
  checking each file's SHA-256 before using it.

## Install

You need an Apple Silicon Mac (M1 or newer) on macOS 14 or later, and about 5 GB of free disk space.
16 GB of RAM is recommended.

1. Download **VENWhispr-x.y.z.dmg** from the [latest release](https://github.com/ventelv/VENWhispr/releases/latest).
2. Open it and drag **VENWhispr** into **Applications**.
3. Open VENWhispr from Applications. Because the app isn't paid-signed by Apple, macOS says it can't
   check it for malicious software. Click **Done**, then open **System Settings → Privacy &
   Security**, scroll down to "VENWhispr was blocked", click **Open Anyway** and confirm. You only do
   this once. (On macOS 14 you can instead right-click the app, choose **Open**, then **Open**.)
4. In the setup window, click **Download** to fetch the speech models (4.3 GB, once).
5. Allow **Microphone** and **Accessibility** when asked. Accessibility is what lets it paste.

Hold **Right ⌥** to dictate in English or **Right ⌘** for Romanian. Change the keys and languages
from Hotkeys & Languages in the menu bar icon.

After installing an update, macOS forgets the Accessibility permission: remove VENWhispr from
System Settings → Privacy & Security → Accessibility and add it again.

## Privacy and security

- Speech recognition and punctuation run on your Mac. The app's only internet connection is the
  one-time model download from Hugging Face, and each model must match a SHA-256 checksum built
  into the app before it's used.
- The speech and punctuation servers listen only on `127.0.0.1`. Because any web page in your
  browser can also send requests to `127.0.0.1`, each launch generates a random secret: the speech
  servers only answer under a secret URL path, and the punctuation server needs it as an API key.
- Logs in `~/Library/Logs/VENWhispr/` hold timings and mic names, never what you said. Your last 20
  dictations are kept in the app's preferences for the Recent menu. Recent → Clear History deletes them.
- Accessibility permission lets the app see the dictation keys system-wide and send ⌘V. It only
  looks at key codes (to cancel on Esc or another key) and never stores keystrokes.
- To paste, the text goes on the clipboard for 1.5 s, marked so clipboard managers skip it, and
  your previous clipboard is put back.
- Download VENWhispr only from this repository's Releases page, and compare the DMG with its
  `.sha256` file if you like (`shasum -a 256 VENWhispr-*.dmg`). Don't run a copy someone sends you.

## Build from source

`./install.sh` builds the app with Homebrew's `whisper.cpp` and `llama.cpp` and downloads the
models. It's safe to run again: finished steps are skipped and interrupted downloads resume.

To make the downloadable, self-contained app instead (needs `brew install cmake`):

```bash
./release.sh
```

It builds `whisper-server` and `llama-server` from pinned, checked sources
(`scripts/build_servers.sh`), bundles them inside the app and writes `build/VENWhispr-<version>.dmg`
with its `.sha256`. `./release.sh publish` also uploads them as a GitHub Release.

`./build.sh install` rebuilds, copies to /Applications and relaunches. With the default ad-hoc
signature macOS forgets the Accessibility grant after each rebuild. Remove VENWhispr from the
Accessibility list and re-add it, or sign with a stable self-made certificate (see `build.sh`).

Logs: `~/Library/Logs/VENWhispr/` (dictation.log, whisper-server.log, whisper-preview.log, llama-server.log)

Memory: about 1.7 GB for Whisper and 2.7 GB for Gemma. Turning Smart Punctuation off unloads Gemma.

## License

VENWhispr is released under the [MIT License](LICENSE). The app bundles whisper.cpp, llama.cpp,
cpp-httplib and nlohmann/json, all MIT-licensed; their notices ship inside the app and the disk
image as `THIRD-PARTY-NOTICES.txt` (generated by `scripts/build_servers.sh`). The models
VENWhispr downloads come from their publishers under their own terms (Whisper: MIT; Gemma: the
Gemma Terms of Use).
