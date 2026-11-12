# Contributing to UTM Watch

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

1. **Open an issue first** for anything bigger than a small fix, so we can agree on the approach. For a bug, include your macOS version, your UTM version, the VM's backend (Apple or QEMU) and what you saw.
2. **Build and check your change.** `swift build -c release` and `swift run selftest` must pass. For app changes, run `Scripts/make-app.sh` and try the change in the real app.
3. **Open a pull request** with a short description of what changed and why. Screenshots help for anything visible.

UI text, code and docs are in plain English. UTM Watch reads VMs read-only and needs no root; please keep it that way.
