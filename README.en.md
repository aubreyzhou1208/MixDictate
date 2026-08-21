<div align="center">

<img src="assets/icon.png" width="128" alt="MixDictate">

# MixDictate

**Menu-bar dictation for macOS · built for mixed Chinese-English speech · fully local**

[中文](README.md) · [Install](#install) · [Usage](#usage) · [Why it exists](#why-it-exists)

</div>

Hold a key, talk, let go — the text lands at your cursor, in any app's text
field, including the terminal.

Audio never leaves the machine. Transcription runs on
[Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) via
[MLX](https://github.com/ml-explore/mlx), on your own GPU.

## Why it exists

Plenty of dictation tools transcribe Chinese, and plenty transcribe English.
Mixing them mid-sentence is where they all fall apart — punctuation goes
half-width, spacing between scripts disappears, and technical terms come back
lowercased.

```
Qwen3-ASR raw       嗯,这个pipeline的latency有点高,我们要不要换个schema?
MixDictate          这个 pipeline 的 latency 有点高，我们要不要换个 schema？
```

The difference is a post-processing layer built specifically for this: sentence
level language detection for punctuation width, spacing between CJK and Latin,
spoken numbers and symbols (「三点一四」 → `3.14`, 「艾特 gmail 点 com」 →
`@gmail.com`), and a hotword table that biases the decoder toward your own
vocabulary.

## Requirements

| | Requirement | How to check |
|---|---|---|
| Machine | Apple Silicon (M1/M2/M3/M4) | ` › About This Mac`, the "Chip" line |
| OS | macOS 13 or newer | Same panel, the "macOS" line |
| Disk | ~3 GB | 1.2 GB model plus Python dependencies |

**Intel Macs cannot run this.** The model is accelerated through Metal, which
is Apple-silicon only.

## Install

### 1. Open Terminal

Press `⌘ + Space`, type `Terminal`, hit Return.

### 2. Clone the repository

```bash
git clone https://github.com/aubreyzhou1208/MixDictate.git ~/MixDictate && cd ~/MixDictate
```

If this is your first time using `git`, macOS will offer to install the Command
Line Developer Tools. Accept, wait for it to finish, then run the line again.

> Install anywhere you like — replace `~/MixDictate`. Every maintenance command
> runs from inside that directory; `./scripts/doctor.sh` prints its full path if
> you forget where it went.

### 3. Run the installer

```bash
./install.sh
```

It checks your machine, creates an isolated Python environment (your system
Python is left alone), installs dependencies, builds the app, moves it into
`/Applications`, launches it, and finishes by re-checking everything.

The first run takes a few minutes, almost all of it downloading dependencies.

### 4. Grant two permissions

A microphone icon appears in the menu bar.

**Microphone** — prompted automatically, click Allow.

**Accessibility** — must be added by hand; macOS never prompts for it:

1. System Settings › Privacy & Security › Accessibility
2. Click `+`
3. Pick **MixDictate** from Applications
4. Turn the switch on

> Without Accessibility the hotkey does *nothing at all* — a global key monitor
> needs that permission just to observe keystrokes, not only to insert text.

### 5. Wait for the model

An hourglass in the menu bar means it is still starting; the first launch pulls
1.2 GB from Hugging Face. A microphone icon means it is ready.

### 6. Say something

In any text field: **hold Right Option, speak, release.** The text appears at
your cursor. Press `Esc` to cancel mid-dictation.

### Strongly recommended: a stable signing identity

```bash
./scripts/signing.sh setup
./install.sh
./scripts/permissions.sh reset
```

Without it, **every rebuild silently invalidates your permissions.** The app is
ad-hoc signed, macOS keys TCC grants by code signature, and an ad-hoc signature
hashes the binary — so a rebuild is, correctly, a different app. The switches in
System Settings still read as "on" while the microphone returns nothing but
zeros. A self-signed certificate costs nothing and needs no Apple ID.

### Optional: start at login

Off by default — after a reboot you open it yourself. To change that, tick
**开机自动启动** in Settings (menu bar › 设置…); it takes effect immediately.
Or from the shell:

```bash
./scripts/autostart.sh install
```

Both touch the same launchd job, so the checkbox and the script agree.

## When something goes wrong

```bash
./scripts/doctor.sh    # collect everything at once
./scripts/verify.sh    # check each known failure, with the fix for each
```

`verify.sh` checks for the specific failures this project has actually hit, and
`install.sh` runs it automatically after every install. Every entry corresponds
to a lesson recorded in [`docs/pitfalls.md`](docs/pitfalls.md).

| Symptom | Usually |
|---|---|
| Hotkey does nothing | Accessibility grant died → `./scripts/permissions.sh reset` |
| Spoke, got nothing | Microphone grant died, same fix |
| Hourglass forever | Model still downloading, or no network |
| No menu bar icon | Hidden behind the notch — every action has a CLI equivalent |

## Usage

- **Hold** the talk key (Right Option by default), **release** to insert
- **Esc** cancels, during recording and during transcription
- Menu bar › Settings for the hotkey, text processing, and input method
- Everything is also reachable from the command line: `./scripts/config.sh`

### Typing as you speak

```bash
./scripts/config.sh set liveInsertion true
```

Text appears at the cursor while you talk instead of arriving on release. The
model revises earlier words as it hears more, so you will see text get deleted
and rewritten — and you should not move the caret mid-dictation, or those
deletions will hit your own text.

## Design notes

The full reasoning lives in the [Chinese README](README.md); the parts most
worth knowing:

**Nearly every failure mode on macOS is silent.** A denied microphone doesn't
raise; `AVAudioConverter` doesn't raise on a channel count it can't map;
`AVAudioEngine` keeps running and hands back zeros. Zeros are byte-identical to
a user who said nothing. So every path that can fail quietly is checked
explicitly and reported in words.

**Echo cancellation is off by default.** macOS's voice processing unit ducks all
other audio for as long as it exists, and the property controlling that is
iOS-only and deprecated. It also switches the input to a multichannel format,
which silently zeroed the microphone until an explicit `channelMap` was added.
Blocking speaker bleed is done with a loudness gate instead — no side effects.

**Punctuation is only ever added or downgraded, never are characters deleted.**
A stray comma is visible and one keystroke to fix; deleted content is something
you never learn existed.

**Pause length is not a reliable punctuation cue while dictating.** "I finished
that sentence" and "I'm working out how to say the next part" are the same
stretch of quiet. Long silences are compressed before inference to remove the
cue, and the text side corrects what survives using the word that follows.

## License

MIT
