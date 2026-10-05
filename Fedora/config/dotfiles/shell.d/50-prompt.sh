# tkoc: git-aware, timed prompt driven by the selected prompt theme.
# This file is also sourced by Zsh, where Liquid Prompt already owns the
# precmd/preexec hooks. Bash's DEBUG trap and PROMPT_COMMAND do not belong there.
if [[ -n ${ZSH_VERSION:-} ]]; then
    # Common xterm/Konsole Ctrl+Arrow sequences. Bind both editing keymaps so
    # the shortcuts work regardless of whether the user chose emacs or vi mode.
    for tkoc_keymap in emacs viins; do
        bindkey -M "$tkoc_keymap" '^[[1;5D' backward-word
        bindkey -M "$tkoc_keymap" '^[[1;5C' forward-word
        bindkey -M "$tkoc_keymap" '^[[5D' backward-word
        bindkey -M "$tkoc_keymap" '^[[5C' forward-word
    done
    unset tkoc_keymap
    return 0
fi

git_prompt_info() {
    [[ ! -d .git && ! $(git rev-parse --is-inside-work-tree 2>/dev/null) == "true" ]] && return

    local branch status ahead behind dirty staged untracked stashed parts
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null)
    status=$(git status --porcelain=2 --branch 2>/dev/null)

    ahead=$(echo "$status" | grep -oP "(?<=ahead )\d+")
    behind=$(echo "$status" | grep -oP "(?<=behind )\d+")
    dirty=$(echo "$status" | grep -E '^[12MADRCU!? ]' | wc -l)
    staged=$(echo "$status" | grep -E '^[1MARC]' | wc -l)
    untracked=$(echo "$status" | grep -E '^\?' | wc -l)
    stashed=$(git stash list 2>/dev/null | wc -l)

    parts=""
    parts+="\[\e[38;5;45m\] $branch\[\e[0m\]"
    [[ $ahead -gt 0 ]] && parts+=" \[\e[38;5;70m\]$ahead\[\e[0m\]"
    [[ $behind -gt 0 ]] && parts+=" \[\e[38;5;124m\]$behind\[\e[0m\]"
    [[ $staged -gt 0 ]] && parts+=" \[\e[38;5;178m\]$staged\[\e[0m\]"
    [[ $dirty -gt 0 ]] && parts+=" \[\e[38;5;208m\]$dirty\[\e[0m\]"
    [[ $untracked -gt 0 ]] && parts+=" \[\e[38;5;210m\]$untracked\[\e[0m\]"
    [[ $stashed -gt 0 ]] && parts+=" \[\e[38;5;98m\]$stashed\[\e[0m\]"

    echo -e "$parts"
}

export TIMER_START

tkoc_preexec() {
    TIMER_START=$(date +%s%N)
}

tkoc_precmd() {
    local TIMER_END TIMER_DIFF
    TIMER_END=$(date +%s%N)
    TIMER_DIFF=$(((TIMER_END - TIMER_START) / 1000000))
    if [[ $TIMER_DIFF -gt 500 ]]; then
        echo -e "\e[38;5;220m Command took $((TIMER_DIFF / 1000)).$((TIMER_DIFF % 1000))s\e[0m"
    fi
    tkoc_update_prompt
}

trap 'tkoc_preexec' DEBUG
PROMPT_COMMAND='EXIT_CODE=$?; tkoc_precmd'

tkoc_update_prompt() {
    local venv user_host cwd git_status exit_code
    venv=""
    [[ -n "$VIRTUAL_ENV" ]] && venv="\[\e[38;5;183m\] ($(basename "$VIRTUAL_ENV")) \[\e[0m\]"

    user_host="${ACCENT1}${USER_ICON} \u ${ACCENT2}${HOST_ICON} \h\[\e[0m\]"
    cwd="${ACCENT3}in ${ACCENT4}${DIR_ICON} \w\[\e[0m\]"

    git_status=""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        git_status=" ${ACCENT1}${GIT_ICON} $(git_prompt_info)\[\e[0m\]"
    fi

    exit_code=""
    if [[ $EXIT_CODE -ne 0 ]]; then
        exit_code="\[\e[38;5;196m\]  $EXIT_CODE\[\e[0m\]"
    fi

    PS1="${venv}${user_host} ${cwd}${git_status}${exit_code}\n "
}
