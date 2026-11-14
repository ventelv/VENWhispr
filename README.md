# VENWhispr

Local, private voice dictation for macOS — a Wispr Flow–style menu bar app.
Hold a key, speak, release: the text is pasted into whatever app has focus.

## Use

| Action | What happens |
|---|---|
| Hold **Right ⌘** | Dictates in English; transcribes and pastes on release |
| Hold **Right ⌥** | Dictates in Romanian |
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
- `WhisperEngine` runs Homebrew's `whisper-server` (whisper.cpp, Metal GPU) on `127.0.0.1:8178` with
  `ggml-large-v3-turbo.bin`, keeping the model warm. Nothing leaves the Mac.
- `LivePreview` shows a draft of your words in a card while you dictate, refreshing about twice a
  second with a separate small model (`preview/ggml-base.bin`, `whisper-server` on `127.0.0.1:8181`,
  about 250 MB). It's only a draft: the pasted text still comes from the main model. Turning Live
  Preview off unloads it.
- `DictationLog` writes one line per dictation (mic, level, timings, outcome — never the text).
- `TextCleaner` strips non-speech tags and English fillers (um, uh, er…) and tidies punctuation.
- `PunctuationEngine` runs `llama-server` (llama.cpp) with Gemma 3 4B on `127.0.0.1:8179` to add
  periods, commas and question marks, only when Whisper's text is a long run-on. Its output is aligned word-by-word back onto Whisper's text, so it
  can only add punctuation/capitals — any word it changes, drops or invents is discarded, and if it
  answers the text instead of punctuating it, Whisper's text is used as-is.
- `AudioDevices` lists microphones via Core Audio and picks the "Automatic" mic: the system default,
  unless that's a Bluetooth headset (AirPods take ~0.5–1.5 s to switch into call mode and cut off
  your first words), in which case a wired mic — USB first, then built-in.
- `OutputMuter` mutes the default output device while recording (music from any app) and restores it,
  touching only what it changed; the saved state survives crashes and is restored at launch.
- `Paster` puts the text on the clipboard, sends ⌘V, then restores your previous clipboard.

## Privacy and security

- Speech recognition and punctuation run on your Mac. The app makes no internet connections; only
  `install.sh` downloads (Homebrew packages, and models from Hugging Face checked by SHA-256).
- The speech and punctuation servers listen only on `127.0.0.1`. Because any web page in your
  browser can also send requests to `127.0.0.1`, each launch generates a random secret: the speech
  servers only answer under a secret URL path, and the punctuation server needs it as an API key.
- Logs in `~/Library/Logs/VENWhispr/` hold timings and mic names, never what you said. Your last 20
  dictations are kept in the app's preferences for the Recent menu. Recent → Clear History deletes them.
- Accessibility permission lets the app see the dictation keys system-wide and send ⌘V. It only
  looks at key codes (to cancel on Esc or another key) and never stores keystrokes.
- To paste, the text goes on the clipboard for 1.5 s, marked so clipboard managers skip it, and
  your previous clipboard is put back.
- Build from source with `install.sh`. A prebuilt copy of the app isn't signed by Apple, so don't
  share or run one from someone else.

## Install

You need an Apple Silicon Mac on macOS 14 or newer, [Homebrew](https://brew.sh), and about 6 GB of
free disk space. 16 GB of RAM is recommended. From a copy of this repo, run:

```bash
./install.sh
```

It installs `whisper.cpp` and `llama.cpp`, downloads and verifies the three models (about 4.3 GB)
into `~/Library/Application Support/VENWhispr`, then builds the app, copies it to /Applications and
opens it. It's safe to run again: finished steps are skipped and interrupted downloads resume.

Grant **Microphone** and **Accessibility** when asked (System Settings → Privacy & Security).

On a new install, Right ⌥ dictates in English and Right ⌘ in Romanian. Change either one from
Hotkeys & Languages in the menu.

## Rebuilding

`./build.sh install` rebuilds, copies to /Applications and relaunches. With the default ad-hoc
signature macOS forgets the Accessibility grant after each rebuild — remove VENWhispr from the
Accessibility list and re-add it, or sign with a stable self-made certificate (see `build.sh`).

Logs: `~/Library/Logs/VENWhispr/` (dictation.log, whisper-server.log, llama-server.log)

Memory: about 1.7 GB for Whisper and 2.7 GB for Gemma. Turning AI Punctuation off unloads Gemma.

## License

VENWhispr is released under the [MIT License](LICENSE). The models that `install.sh` downloads come
from their publishers under their own terms (Whisper: MIT; Gemma: the Gemma Terms of Use).
