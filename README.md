## The KING of Casual
Clone it and run `make`. That links one command, `tkoc`, into `~/.local/bin`.
Nothing is downloaded, nothing is chosen for you, and no shell config is edited.

```bash
cd the_king_of-casual
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

## Security focused command-line wrapper 
With the tkoc commandline you can tailor your firewall, apply a very good nftables,
and utilize tooling within that you may find helpful. 

There's a long & boring story you can view on the macOS version of this:
https://github.com/j0hnporks303/the_king_of_maCasual
