# Setting the project up on the Mac Mini

Everything below is run **on the Mac Mini**, in Terminal. Copy one block at a
time and wait for it to finish.

Two different jobs, so start by deciding which you are doing:

* **Just running the booth on the Mini?** You do not need any of this. Install
  `Photobooth.dmg` and stop — the app carries everything it needs.
* **Continuing to work on the project there?** Carry on.

---

## Step 1 — Developer tools

```bash
xcode-select --install
```

A window appears; click **Install** and wait (a few minutes). This gives you
`git`, `swiftc` and `clang`. If it says *"already installed"*, good — move on.

Check it worked:

```bash
git --version && swiftc --version
```

---

## Step 2 — Homebrew and the camera libraries

The build needs two libraries the camera talks through. Skip this and `./build.sh`
stops with `brew: command not found`.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

On an Apple Silicon Mac, Homebrew then tells you to add itself to your shell.
Do it — this is the step people miss:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Now the libraries:

```bash
brew install libgphoto2 libexif
```

Check:

```bash
brew --prefix libgphoto2
```

It should print `/opt/homebrew/opt/libgphoto2`.

---

## Step 3 — Let git talk to GitHub

The repository is **private**, so cloning asks who you are. GitHub does not
accept your account password here — it wants a **personal access token**.

If you already made one on the other Mac you can reuse it. Otherwise:
github.com → your picture → **Settings** → **Developer settings** →
**Personal access tokens** → **Fine-grained tokens** → **Generate new token** →
select the `photobooth-mac` repository → **Repository permissions** →
**Contents: Read and write** → Generate. Copy it somewhere for a moment; GitHub
shows it once.

Tell git to remember it in the Keychain so you only type it once:

```bash
git config --global credential.helper osxkeychain
git config --global user.name "Sean Amador"
git config --global user.email "mixel.org@gmail.com"
```

---

## Step 4 — Clone the project

**The path matters.** Use exactly this one, so Claude Code finds the notes it
has been keeping about this project:

```bash
mkdir -p ~/Movies/Work/CLAUDE
cd ~/Movies/Work/CLAUDE
git clone https://github.com/mixelorg-arch/photobooth-mac.git Photobooth
```

Username: `mixelorg-arch`. Password: **paste the token**, not your password.
Nothing appears as you paste — that is normal. Press Return.

You should now have `~/Movies/Work/CLAUDE/Photobooth` with `Sources`, `Tools`,
`build.sh` and the rest inside it.

---

## Step 5 — Build it

```bash
cd ~/Movies/Work/CLAUDE/Photobooth
./build.sh
```

Ends with `BUILD OK → dist/Photobooth.app`. Then, for an installer:

```bash
./make_dmg.sh
```

Run what you just built:

```bash
open dist/Photobooth.app
```

First launch only: **right-click** the app → **Open** → **Open** in the dialog.
The app is signed ad-hoc rather than with an Apple developer certificate, so
macOS asks once.

---

## Step 6 — Bring your setup across (optional)

None of this is in the repository — client photographs do not belong in source
control. Copy from the old Mac only what you need.

| What | Where | Size |
|---|---|---|
| Settings, Cloudinary details, upload queue | `~/Library/Application Support/Photobooth/` | 79 MB |
| Photographs and album passwords | `~/Pictures/Photobooth/` | 99 MB |
| Album pages already sent to clients | `~/Documents/photobooth-albums/` | small |

Over the network, run this **on the old Mac** with the Mini turned on and
Remote Login enabled (System Settings → General → Sharing → Remote Login):

```bash
rsync -av ~/Library/Application\ Support/Photobooth/ seanamador@macmini.local:~/Library/Application\ Support/Photobooth/
```

An external disk or AirDrop does the same job. Afterwards, open **Admin →
Printer** on the Mini and pick the SELPHY: the printer has to be added in System
Settings there first, and the name is part of the settings you copied.

To keep Claude Code's memory of this project, also copy:

```bash
rsync -av ~/.claude/projects/-Users-seanamador-Movies-Work-CLAUDE/ seanamador@macmini.local:~/.claude/projects/-Users-seanamador-Movies-Work-CLAUDE/
```

---

## Step 7 — Permissions the Mini asks for on its own

Per-machine, so they do not travel:

* **Input Monitoring** — needed for the USB booth button to work when Photobooth
  is not the front window. Admin → Booth Button → **Grant Access**. macOS asks
  again after each new build you install, because the app is ad-hoc signed.
* **Camera** — quit Image Capture and Photos before plugging the 6D in.

---

## Working across two Macs from now on

Start of a session, on whichever Mac you are at:

```bash
git pull
```

End of a session:

```bash
git add -A && git commit -m "what you changed" && git push
```

The rule that keeps this painless: **push before you walk away from a Mac.** If
you edit the same files on both without pushing, git will ask you to merge them
by hand.

To see whether you are behind:

```bash
git status && git log --oneline -5
```

---

## When something goes wrong

**`brew: command not found`** — Step 2's `~/.zprofile` line was skipped, or the
Terminal window predates it. Close the window, open a new one.

**`xcrun: error: invalid active developer path`** — Step 1 did not finish. Run
`xcode-select --install` again.

**`Authentication failed` when cloning** — you typed your GitHub password
instead of a token, or the token has no access to that repository. Make a new
fine-grained token with Contents: Read and write, then:
`git credential-osxkeychain erase` (type `host=github.com`, `protocol=https`,
then Return twice) and clone again.

**`fatal: not a git repository`** — you are in the wrong folder.
`cd ~/Movies/Work/CLAUDE/Photobooth` first.

**`./build.sh: Permission denied`** — `chmod +x *.sh` in the project folder.

**"Photobooth is damaged and can't be opened"** — Gatekeeper on a downloaded
copy. Build it yourself with `./build.sh` rather than copying the .app across,
or `xattr -dr com.apple.quarantine dist/Photobooth.app`.

**The camera is not found** — Photos or Image Capture has claimed it. Quit both,
then Admin → Camera → Connect.
