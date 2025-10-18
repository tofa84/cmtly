# 🚀 cmtly

`cmtly` is a lightweight CLI that turns your staged Git diff into a polished commit message. It taps into Apple Foundation Models to summarize the diff, then copies a ready-to-run `git commit` command to your clipboard. Stage your changes, run `cmtly`, and commit with confidence. ✨

## 🛠 Requirements

- macOS 26 or newer (Apple Foundation Models require it)
- Xcode Command Line Tools (`xcode-select --install`)
- Git installed and available on your PATH

## 📦 Installation

Run the installer script:

```bash
scripts/install.sh
```

The script builds `cmtly`, installs the binary at `~/.cmtly/bin/cmtly`, and reminds you to add the directory to your PATH so the command is available in future shells.

### 🔧 Add `cmtly` to your PATH

Pick the snippet for your shell and run it once:

- zsh → `echo 'export PATH="$HOME/.cmtly/bin:$PATH"' >> ~/.zshrc`
- bash → `echo 'export PATH="$HOME/.cmtly/bin:$PATH"' >> ~/.bash_profile`
- fish → `set -U fish_user_paths $HOME/.cmtly/bin $fish_user_paths`

After updating your profile, restart the terminal (or source the file) and verify:

```bash
which cmtly
```

## 🧪 Usage

1. Stage your changes: `git add .`
2. Generate a message: `cmtly`
3. Review the summary, then paste the copied `git commit` command (already added to your clipboard) and hit enter ✅

`cmtly` exits with a descriptive message if:

- You are outside a Git repository
- No staged changes are detected
- The Apple Foundation Model service is unavailable

## 🆘 Troubleshooting

- **`cmtly` not found:** Ensure `~/.cmtly/bin` appears in `echo $PATH` and that you restarted your shell.
- **Model availability errors:** Make sure you are on macOS 15+ and signed into an Apple ID that can access Foundation Models.
- **Git errors:** Confirm Git is installed and that you are inside a repository with staged changes.

Happy committing! 💚
