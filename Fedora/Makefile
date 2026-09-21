# the_king_of-casual (Fedora edition) -- install
#
# Everything this project does runs through one command: tkoc. Installing it
# means putting one symlink on your PATH. That is all the default target does.
#
#   make             link tkoc into ~/.local/bin
#   make root-tools  install root-owned copies of the privileged tools
#   make uninstall   remove that symlink
#   make purge       remove tkoc from this machine
#   make check       verify the link resolves, runs, and is not stale
#   make test        run the structural test suites
#
# No PATH files are edited, no repo is cloned or deleted, nothing is chosen for
# you. Override the destination with:  make BIN_DIR=/somewhere/else

SHELL := /bin/bash

BIN_DIR ?= $(HOME)/.local/bin
REPO_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TARGET   := $(REPO_DIR)/tools/tkoc.sh
LINK     := $(BIN_DIR)/tkoc

# Root's tools live apart from yours, and are COPIES rather than symlinks.
# A symlink from a root path back into ~/.local/bin or the checkout would mean
# root executing a file your user account can rewrite -- that is a local
# privilege escalation, not a convenience. These copies are root-owned and
# writable only by root, so `sudo tkoc-lockdown` cannot be hijacked by anything
# running as you. Re-run `make root-tools` after pulling to refresh them.
ROOT_LIBEXEC := /usr/local/libexec/tkoc
ROOT_SBIN    := /usr/local/sbin

ROOT_FILES := tools/downlock.sh tools/lockdown.sh tools/network-profile.sh \
              stages/lib/common.sh stages/lib/state.sh stages/lib/persistence.sh \
              config/downlock.json config/network-profiles.json

.PHONY: install root-tools root-tools-verify root-tools-remove uninstall purge check test help

install:
	@[ -f "$(TARGET)" ] || { echo "error: $(TARGET) not found -- run make from inside the checkout"; exit 1; }
	@chmod +x "$(TARGET)"
	@mkdir -p "$(BIN_DIR)"
	@ln -sfn "$(TARGET)" "$(LINK)"
	@echo "linked  $(LINK) -> $(TARGET)"
	@echo
	@case ":$$PATH:" in \
	  *":$(BIN_DIR):"*) ;; \
	  *) echo "NOTE: $(BIN_DIR) is not on your PATH. Add this to ~/.bashrc:"; \
	     echo "        export PATH=\"$(BIN_DIR):\$$PATH\""; \
	     echo ;; \
	esac
	@echo "Usage:"
	@echo "  tkoc help                 every command"
	@echo "  tkoc check                read-only pre-flight"
	@echo "  tkoc status               what the machine looks like now"
	@echo "  tkoc harden strong        privacy + firewall, the sane default"
	@echo "  tkoc firewall lockdown    strictest network posture"
	@echo
	@echo "Add --dry-run to any command to see what it would do, changing nothing."
	@echo
	@echo "Applying a firewall tier disables and masks firewalld, after asking."
	@echo "firewalld also manages nftables; the two cannot both own the ruleset."

uninstall:
	@# Refuse to strip the command while boot-time policy is still installed.
	@# nftables.service keeps loading the tkoc ruleset at every boot, and the
	@# NetworkManager dispatcher keeps setting DNS, with nothing left on the
	@# machine able to turn either off. `make purge` is the way out.
	@resid=""; \
	for p in /etc/nftables/tkoc.nft /etc/NetworkManager/dispatcher.d/90-tkoc-network-watch; do \
	  [ -e "$$p" ] && resid="$$resid $$p"; \
	done; \
	if [ -n "$$resid" ]; then \
	  echo "REFUSING: tkoc policy is still installed on this machine:"; \
	  for p in $$resid; do echo "    $$p"; done; \
	  echo; \
	  echo "These are re-applied at every boot by nftables.service and"; \
	  echo "NetworkManager. Removing the command now would leave them running"; \
	  echo "with nothing able to stop them."; \
	  echo; \
	  echo "Remove tkoc properly first:"; \
	  echo "    make purge          # undo the firewall, sysctl, and dispatcher"; \
	  echo "Then, if you still want to:"; \
	  echo "    make uninstall      # remove the symlink"; \
	  echo; \
	  echo "To strip the symlink anyway and deal with the rest yourself:"; \
	  echo "    make uninstall FORCE=1"; \
	  [ -n "$(FORCE)" ] || exit 1; \
	  echo "FORCE=1 given -- proceeding anyway."; \
	fi
	@# Only remove a link that points into THIS checkout. The macOS edition
	@# uses the same name, and removing its working command would be damage.
	@if [ -L "$(LINK)" ]; then \
	  dest=$$(readlink -f "$(LINK)" 2>/dev/null || readlink "$(LINK)"); \
	  case "$$dest" in \
	    "$(REPO_DIR)"/*) rm -f "$(LINK)"; echo "removed $(LINK)" ;; \
	    *) echo "left $(LINK) alone: it points at $$dest, outside this checkout" ;; \
	  esac; \
	else \
	  echo "nothing to remove at $(LINK)"; \
	fi
	@echo "The checkout at $(REPO_DIR) was left alone. Delete it yourself if you want it gone."

purge:
	@bash "$(REPO_DIR)/tools/uninstall.sh" --apply

root-tools:
	@echo "Installing root-owned copies of the privileged tools."
	@echo "Copies, not symlinks: root must never execute a file your user can write."
	@echo
	sudo install -d -o root -g root -m 0755 "$(ROOT_LIBEXEC)" \
	  "$(ROOT_LIBEXEC)/tools" "$(ROOT_LIBEXEC)/stages" "$(ROOT_LIBEXEC)/stages/lib" \
	  "$(ROOT_LIBEXEC)/config" "$(ROOT_SBIN)"
	@for f in $(ROOT_FILES); do \
	  case "$$f" in *.sh) mode=0755 ;; *) mode=0644 ;; esac; \
	  sudo install -o root -g root -m $$mode "$(REPO_DIR)/$$f" "$(ROOT_LIBEXEC)/$$f"; \
	done
	@# HOME is pinned to root's own home so root-created recovery snapshots
	@# land in /root/.local/state, never in your user state directory.
	@# mktemp, not a predictable /tmp name: /tmp is world-writable, and a
	@# pre-created symlink at a guessable path would redirect this write.
	@for t in downlock lockdown; do \
	  tmp=$$(mktemp "$${TMPDIR:-/tmp}/tkoc-shim.XXXXXX") || exit 1; \
	  printf '#!/usr/bin/env bash\n# root-owned copy -- do not edit; regenerate with: make root-tools\nHOME=/root exec /usr/bin/env bash %s/tools/%s.sh "$$@"\n' "$(ROOT_LIBEXEC)" "$$t" > "$$tmp"; \
	  sudo install -o root -g root -m 0755 "$$tmp" "$(ROOT_SBIN)/tkoc-$$t"; \
	  rm -f "$$tmp"; \
	done
	@echo
	@$(MAKE) --no-print-directory root-tools-verify
	@echo
	@echo "Ready. Report on root-owned file permissions (changes nothing):"
	@echo "    sudo tkoc-lockdown"
	@echo "Apply them:"
	@echo "    sudo tkoc-lockdown --apply --yes"

root-tools-verify:
	@echo "Verifying nothing in the root tree is writable by a non-root user:"
	@bad=$$(find "$(ROOT_LIBEXEC)" "$(ROOT_SBIN)/tkoc-downlock" "$(ROOT_SBIN)/tkoc-lockdown" \
	         \( ! -user root -o -perm -0022 \) -print 2>/dev/null); \
	if [ -n "$$bad" ]; then echo "  INSECURE -- these are not root-owned or are group/world writable:"; \
	  echo "$$bad" | sed 's/^/    /'; exit 1; \
	else echo "  ok: every file is root-owned and root-writable only"; fi
	@echo "Verifying they are real files, not links back into your home:"
	@for f in "$(ROOT_SBIN)/tkoc-downlock" "$(ROOT_LIBEXEC)/tools/downlock.sh"; do \
	  if [ -L "$$f" ]; then echo "  INSECURE: $$f is a symlink"; exit 1; fi; done
	@echo "  ok: real copies"

root-tools-remove:
	@sudo rm -rf "$(ROOT_LIBEXEC)"
	@sudo rm -f "$(ROOT_SBIN)/tkoc-downlock" "$(ROOT_SBIN)/tkoc-lockdown"
	@echo "removed the root-owned tool copies"

check:
	@[ -L "$(LINK)" ] || { echo "not linked -- run: make"; exit 1; }
	@[ -e "$(LINK)" ] || { echo "DANGLING: $(LINK) -> $$(readlink "$(LINK)")"; \
	  echo "The checkout moved or was deleted. Re-run 'make' from where it lives now."; exit 1; }
	@echo "link    $(LINK) -> $$(readlink "$(LINK)")"
	@"$(LINK)" help >/dev/null 2>&1 && echo "runs    ok" || { echo "runs    FAILED"; exit 1; }
	@# Root's tools are copies, so they go stale silently after a git pull.
	@# Root running last week's code is a security problem, not a cosmetic one.
	@if [ -d "$(ROOT_LIBEXEC)" ]; then \
	  drift=""; \
	  for f in $(ROOT_FILES); do \
	    if [ -e "$(ROOT_LIBEXEC)/$$f" ] && ! cmp -s "$(REPO_DIR)/$$f" "$(ROOT_LIBEXEC)/$$f"; then \
	      drift="$$drift $$f"; \
	    fi; \
	  done; \
	  if [ -n "$$drift" ]; then \
	    echo "root    STALE -- these differ from the checkout:"; \
	    for f in $$drift; do echo "          $$f"; done; \
	    echo "          refresh with: make root-tools"; \
	  else \
	    echo "root    ok (copies match the checkout)"; \
	  fi; \
	else \
	  echo "root    not installed (optional: make root-tools)"; \
	fi
	@# Leftovers from a partial removal keep enforcing policy with nothing
	@# obvious left to point at.
	@resid=""; \
	for p in /etc/nftables/tkoc.nft /etc/sysctl.d/60-tkoc-hardening.conf \
	         /etc/NetworkManager/dispatcher.d/90-tkoc-network-watch; do \
	  [ -e "$$p" ] && resid="yes"; \
	done; \
	if [ -n "$$resid" ]; then \
	  echo "system  tkoc policy is installed on this machine ('make purge' removes it)"; \
	else \
	  echo "system  clean"; \
	fi

test:
	@bash "$(REPO_DIR)/tests/regression.sh"
	@bash "$(REPO_DIR)/tests/test-tkoc.sh"

help:
	@echo "make                     link tkoc into $(BIN_DIR)"
	@echo "make root-tools          install root-owned copies: sudo tkoc-downlock / tkoc-lockdown"
	@echo "make root-tools-remove   remove those root copies"
	@echo "make uninstall           remove the symlink only"
	@echo "make purge               remove tkoc from this machine (firewall, sysctl, dispatcher)"
	@echo "make check               verify the link resolves, runs, and is not stale"
	@echo "make test                run the structural test suites"
	@echo "make BIN_DIR=X           install somewhere other than $(BIN_DIR)"
