#!/bin/bash
# EC2 user-data: Amazon Linux 2023 (arm64/x86_64) development environment.
#   python3.14, Node.js 22, zsh, tmux, git, htop, kiro-cli, herdr
#   [optional block] powerlevel10k + ~/.p10k.zsh  (INSTALL_P10K, or delete the block)
#
# Runs as root via cloud-init on first boot. Safe to re-run (idempotent).
# Log: /var/log/devenv-setup.log    Done marker: /var/lib/devenv-setup.done
#
# Launch-time requirements that user-data cannot set:
#   - Instance profile with AmazonSSMManagedInstanceCore (Session Manager)
#   - Outbound HTTPS to dnf repos, github.com, cli.kiro.dev, herdr.dev
set -euxo pipefail
exec > >(tee -a /var/log/devenv-setup.log) 2>&1

# ---------- settings ----------
# Values come from the settings block at the top of deploy.sh, which writes
# them as NAME=value lines right after the shebang. Every NAME="${NAME...}"
# line below must have a matching export there, or deploy.sh stops.
TARGET_USER="${TARGET_USER:?}"
NODE_MAJOR="${NODE_MAJOR:?}"
PYTHON_VER="${PYTHON_VER:?}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:?}"
INSTALL_DOCKER="${INSTALL_DOCKER:?}"
INSTALL_P10K="${INSTALL_P10K:?}"
GIT_USER_NAME="${GIT_USER_NAME?}"     # may be empty
GIT_USER_EMAIL="${GIT_USER_EMAIL?}"   # may be empty
# -------------------------------

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# ---------- system packages ----------
dnf install -y \
  zsh util-linux-user tmux git htop jq unzip tar \
  "python${PYTHON_VER}" "python${PYTHON_VER}-pip" \
  "nodejs${NODE_MAJOR}" "nodejs${NODE_MAJOR}-npm"

# nodejsNN packages register node/npm/npx through alternatives.
for bin in node npm npx; do
  if [ ! -e "/usr/bin/${bin}" ] && [ -e "/usr/bin/${bin}-${NODE_MAJOR}" ]; then
    alternatives --set "${bin}" "/usr/bin/${bin}-${NODE_MAJOR}" || ln -sf "/usr/bin/${bin}-${NODE_MAJOR}" "/usr/bin/${bin}"
  fi
done

if [ "$INSTALL_DOCKER" = "true" ]; then
  dnf install -y docker
  systemctl enable --now docker
  usermod -aG docker "$TARGET_USER"
fi

# ---------- swap ----------
if [ "$SWAP_SIZE_MB" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  if [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

# ---------- login shell ----------
usermod -s /usr/bin/zsh "$TARGET_USER"

# ---------- user-level setup ----------
sudo -u "$TARGET_USER" -H \
  PYTHON_VER="$PYTHON_VER" GIT_USER_NAME="$GIT_USER_NAME" GIT_USER_EMAIL="$GIT_USER_EMAIL" \
  bash -euxo pipefail -s <<'EOF_USER'
cd "$HOME"
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
mkdir -p "$HOME/.local/bin" "$HOME/.config/herdr" "$HOME/.bashrc.d"

# ~/.zshrc (overwritten only if it is missing or was written by this script)
if [ ! -f "$HOME/.zshrc" ] || grep -q 'managed-by: devenv-user-data' "$HOME/.zshrc"; then
  cat > "$HOME/.zshrc" <<EOF_ZSHRC
# managed-by: devenv-user-data
# Powerlevel10k instant prompt (no-op without p10k). Should stay close to the top of ~/.zshrc.
if [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then
  source "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"
fi

# powerlevel10k (only when the optional block installed it)
[[ ! -r ~/powerlevel10k/powerlevel10k.zsh-theme ]] || source ~/powerlevel10k/powerlevel10k.zsh-theme
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

typeset -U path
path=("\$HOME/.local/bin" "\$HOME/bin" \$path)
export PATH

# herdr helpers
ha() {
    { herdr agent start "\$1" --kind kiro --pane "\$HERDR_PANE_ID" && herdr pane rename "\$HERDR_PANE_ID" "\$1"; } > /dev/null &!
}
hta() {
    { herdr agent start "\$1" --pane "\$HERDR_PANE_ID" --kind kiro -- chat --trust-all-tools && herdr pane rename "\$HERDR_PANE_ID" "\$1"; } > /dev/null &!
}
alias ha-prompt="herdr agent prompt"

alias python='/usr/bin/python${PYTHON_VER}'
EOF_ZSHRC
fi

# bash (ssm-user / fallback shells): AL2023 ~/.bashrc sources ~/.bashrc.d/*
cat > "$HOME/.bashrc.d/devenv.sh" <<EOF_BASH
ha() { herdr agent start "\$1" --kind kiro --pane "\$HERDR_PANE_ID" > /dev/null & }
alias ha-prompt="herdr agent prompt"
alias python='/usr/bin/python${PYTHON_VER}'
EOF_BASH

# herdr config
[ -f "$HOME/.config/herdr/config.toml" ] || cat > "$HOME/.config/herdr/config.toml" <<'EOF_HERDR'
onboarding = false

[terminal]
default_shell = "/usr/bin/zsh"

[ui.sound]
enabled = false
EOF_HERDR

# git identity
[ -n "$GIT_USER_NAME" ]  && git config --global user.name  "$GIT_USER_NAME"
[ -n "$GIT_USER_EMAIL" ] && git config --global user.email "$GIT_USER_EMAIL"

# kiro-cli (installer asks for confirmation on reinstall, so skip when present)
if [ ! -x "$HOME/.local/bin/kiro-cli" ]; then
  curl -fsSL https://cli.kiro.dev/install | bash
fi

# herdr
if [ ! -x "$HOME/.local/bin/herdr" ]; then
  curl -fsSL https://herdr.dev/install.sh | sh
fi
EOF_USER

# >>>>>>>>>>>>>>>>>>>> [optional] powerlevel10k >>>>>>>>>>>>>>>>>>>>
# Self-contained: delete everything from here to the matching "<<<<" line, or set
# INSTALL_P10K="false", to skip it. ~/.zshrc loads p10k only if these files exist.
if [ "${INSTALL_P10K:-false}" = "true" ]; then
P10K_COMMIT="d05a1b00f9a61f9578bf9dc19b8451942dde8734"   # romkatv/powerlevel10k
P10K_SHA256="f9a50f41b7ad2e76617fe9767cacc9ac1e14219ba2bc073ce263ceb2d475df40"  # expected ~/.p10k.zsh
sudo -u "$TARGET_USER" -H P10K_COMMIT="$P10K_COMMIT" P10K_SHA256="$P10K_SHA256" \
  bash -euxo pipefail -s <<'EOF_P10K_USER'
cd "$HOME"
# powerlevel10k, pinned so the ~/.p10k.zsh patch below applies exactly
if [ ! -d "$HOME/powerlevel10k/.git" ]; then
  git init -q "$HOME/powerlevel10k"
  git -C "$HOME/powerlevel10k" remote add origin https://github.com/romkatv/powerlevel10k.git
  git -C "$HOME/powerlevel10k" fetch -q --depth=1 origin "$P10K_COMMIT"
  git -C "$HOME/powerlevel10k" checkout -q FETCH_HEAD
fi
# Pre-download gitstatusd so the first prompt does not wait for it.
"$HOME/powerlevel10k/gitstatus/install" || echo "WARN: gitstatusd download failed; p10k retries on first prompt"

# ~/.p10k.zsh = config/p10k-classic.zsh + the wizard choices below
#   nerdfont-v3 + powerline, small icons, classic, unicode, dark, 24h time, vertical separators,
#   sharp heads/tails, 2 lines, solid, right frame, compact, few icons, concise, transient_prompt
if [ ! -f "$HOME/.p10k.zsh" ]; then
  p10k_tmp="$(mktemp -d)"
  cp "$HOME/powerlevel10k/config/p10k-classic.zsh" "$p10k_tmp/p10k.zsh"
  if (cd "$p10k_tmp" && git apply) <<'EOF_P10K' && echo "$P10K_SHA256  $p10k_tmp/p10k.zsh" | sha256sum -c -
--- a/p10k.zsh
+++ b/p10k.zsh
@@ -1 +1,8 @@
+# Generated by Powerlevel10k configuration wizard on 2026-10-26 at 05:59 UTC.
+# Based on romkatv/powerlevel10k/config/p10k-classic.zsh, checksum 08429.
+# Wizard options: nerdfont-v3 + powerline, small icons, classic, unicode, dark,
+# 24h time, vertical separators, sharp heads, sharp tails, 2 lines, solid, right frame,
+# compact, few icons, concise, transient_prompt, instant_prompt=verbose.
+# Type `p10k configure` to generate another config.
+#
 # Config for Powerlevel10k with classic powerline prompt style. Type `p10k configure` to generate
@@ -32,3 +39,3 @@
     newline                 # \n
-    # prompt_char           # prompt symbol
+    prompt_char             # prompt symbol
   )
@@ -102,3 +109,3 @@
     # cpu_arch              # CPU architecture
-    # time                  # current time
+    time                    # current time
     # =========================[ Line #2 ]=========================
@@ -114,3 +121,3 @@
   # Defines character set used by powerlevel10k. It's best to let `p10k configure` set it for you.
-  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
+  typeset -g POWERLEVEL9K_MODE=nerdfont-v3
   # When set to `moderate`, some icons will have an extra space after them. This is meant to avoid
@@ -133,3 +140,3 @@
   # Add an empty line before each prompt.
-  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
+  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=false
 
@@ -137,9 +144,9 @@
   # as POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_FOREGROUND below.
-  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX='%242F╭─'
-  typeset -g POWERLEVEL9K_MULTILINE_NEWLINE_PROMPT_PREFIX='%242F├─'
-  typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX='%242F╰─'
+  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX=
+  typeset -g POWERLEVEL9K_MULTILINE_NEWLINE_PROMPT_PREFIX=
+  typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX=
   # Connect right prompt lines with these symbols.
-  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_SUFFIX='%242F─╮'
-  typeset -g POWERLEVEL9K_MULTILINE_NEWLINE_PROMPT_SUFFIX='%242F─┤'
-  typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_SUFFIX='%242F─╯'
+  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_SUFFIX='%240F─╮'
+  typeset -g POWERLEVEL9K_MULTILINE_NEWLINE_PROMPT_SUFFIX='%240F─┤'
+  typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_SUFFIX='%240F─╯'
 
@@ -149,3 +156,3 @@
   # for more compact prompt if using this option.
-  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_CHAR=' '
+  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_CHAR='─'
   typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_BACKGROUND=
@@ -155,3 +162,3 @@
     # ornaments defined above.
-    typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_FOREGROUND=242
+    typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_FOREGROUND=240
     # Start filler from the edge of the screen if there are no left segments on the first line.
@@ -163,12 +170,12 @@
   # Default background color.
-  typeset -g POWERLEVEL9K_BACKGROUND=238
+  typeset -g POWERLEVEL9K_BACKGROUND=236
 
   # Separator between same-color segments on the left.
-  typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR='%246F\uE0B1'
+  typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR='%244F\u2502'
   # Separator between same-color segments on the right.
-  typeset -g POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR='%246F\uE0B3'
+  typeset -g POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR='%244F\u2502'
   # Separator between different-color segments on the left.
-  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR='\uE0B0'
+  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR=''
   # Separator between different-color segments on the right.
-  typeset -g POWERLEVEL9K_RIGHT_SEGMENT_SEPARATOR='\uE0B2'
+  typeset -g POWERLEVEL9K_RIGHT_SEGMENT_SEPARATOR=''
   # To remove a separator between two segments, add "_joined" to the second segment name.
@@ -181,5 +188,5 @@
   # The left end of left prompt.
-  typeset -g POWERLEVEL9K_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL=
+  typeset -g POWERLEVEL9K_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL='\uE0B2'
   # The right end of right prompt.
-  typeset -g POWERLEVEL9K_RIGHT_PROMPT_LAST_SEGMENT_END_SYMBOL=
+  typeset -g POWERLEVEL9K_RIGHT_PROMPT_LAST_SEGMENT_END_SYMBOL='\uE0B0'
   # Left prompt terminator for lines without any segments.
@@ -346,6 +353,6 @@
   #
-  # typeset -g POWERLEVEL9K_DIR_CLASSES=()
+  typeset -g POWERLEVEL9K_DIR_CLASSES=()
 
   # Custom prefix.
-  # typeset -g POWERLEVEL9K_DIR_PREFIX='%248Fin '
+  # typeset -g POWERLEVEL9K_DIR_PREFIX='%246Fin '
 
@@ -379,3 +386,3 @@
       # Styling for up-to-date Git status.
-      local       meta='%248F'  # grey foreground
+      local       meta='%246F'  # grey foreground
       local      clean='%76F'   # green foreground
@@ -499,5 +506,5 @@
   # Custom icon.
-  # typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_EXPANSION='⭐'
+  typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_EXPANSION=
   # Custom prefix.
-  # typeset -g POWERLEVEL9K_VCS_PREFIX='%248Fon '
+  # typeset -g POWERLEVEL9K_VCS_PREFIX='%246Fon '
 
@@ -521,3 +528,3 @@
   # it will signify success by turning green.
-  typeset -g POWERLEVEL9K_STATUS_OK=true
+  typeset -g POWERLEVEL9K_STATUS_OK=false
   typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=70
@@ -533,3 +540,3 @@
   # it will signify error by turning red.
-  typeset -g POWERLEVEL9K_STATUS_ERROR=true
+  typeset -g POWERLEVEL9K_STATUS_ERROR=false
   typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=160
@@ -560,5 +567,5 @@
   # Custom icon.
-  # typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_VISUAL_IDENTIFIER_EXPANSION='⭐'
+  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_VISUAL_IDENTIFIER_EXPANSION=
   # Custom prefix.
-  # typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PREFIX='%248Ftook '
+  # typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PREFIX='%246Ftook '
 
@@ -943,3 +950,3 @@
   # Custom prefix.
-  # typeset -g POWERLEVEL9K_CONTEXT_PREFIX='%248Fwith '
+  # typeset -g POWERLEVEL9K_CONTEXT_PREFIX='%246Fwith '
 
@@ -1374,3 +1381,3 @@
   # Custom prefix.
-  # typeset -g POWERLEVEL9K_KUBECONTEXT_PREFIX='%248Fat '
+  # typeset -g POWERLEVEL9K_KUBECONTEXT_PREFIX='%246Fat '
 
@@ -1564,3 +1571,3 @@
   # Custom prefix.
-  # typeset -g POWERLEVEL9K_TOOLBOX_PREFIX='%248Fin '
+  # typeset -g POWERLEVEL9K_TOOLBOX_PREFIX='%246Fin '
 
@@ -1625,3 +1632,3 @@
   # Battery pictograms going from low to high level of charge.
-  typeset -g POWERLEVEL9K_BATTERY_STAGES=('%K{232}▁' '%K{232}▂' '%K{232}▃' '%K{232}▄' '%K{232}▅' '%K{232}▆' '%K{232}▇' '%K{232}█')
+  typeset -g POWERLEVEL9K_BATTERY_STAGES='\UF008E\UF007A\UF007B\UF007C\UF007D\UF007E\UF007F\UF0080\UF0081\UF0082\UF0079'
   # Don't show the remaining time to charge/discharge.
@@ -1665,5 +1672,5 @@
   # Custom icon.
-  # typeset -g POWERLEVEL9K_TIME_VISUAL_IDENTIFIER_EXPANSION='⭐'
+  typeset -g POWERLEVEL9K_TIME_VISUAL_IDENTIFIER_EXPANSION=
   # Custom prefix.
-  # typeset -g POWERLEVEL9K_TIME_PREFIX='%248Fat '
+  # typeset -g POWERLEVEL9K_TIME_PREFIX='%246Fat '
 
@@ -1708,3 +1715,3 @@
   #               typed after changing current working directory.
-  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off
+  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always
 
EOF_P10K
  then
    mv "$p10k_tmp/p10k.zsh" "$HOME/.p10k.zsh"
  else
    echo "WARN: p10k patch failed; using plain p10k-classic preset"
    cp "$HOME/powerlevel10k/config/p10k-classic.zsh" "$HOME/.p10k.zsh"
  fi
  rm -rf "$p10k_tmp"
fi
EOF_P10K_USER
fi
# <<<<<<<<<<<<<<<<<<<< [optional] powerlevel10k <<<<<<<<<<<<<<<<<<<<

touch /var/lib/devenv-setup.done
echo "devenv setup finished"
