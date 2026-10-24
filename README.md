## The KING of Casual
Clone it and run `make`. That links one command, `tkoc`, into `~/.local/bin`.
Nothing is downloaded, nothing is chosen for you, and no shell config is edited.

```bash
cd Fedora
make
```

If `~/.local/bin` isn't on your PATH, `make` says so and prints the one line to
add. Install elsewhere with `make BIN_DIR=/somewhere/else`.

```bash
make            # link tkoc into ~/.local/bin
make check      # verify the link resolves, runs, and is not stale
make root-tools # root-owned copies of the privileged tools (optional)
make uninstall  # remove the symlink; the checkout is left alone
make purge      # remove tkoc from this machine
```

