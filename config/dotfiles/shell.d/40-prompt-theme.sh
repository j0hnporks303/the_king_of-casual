# tkoc: load the selected prompt theme's accent colors and icons.
tkoc_prompt_theme_file="${XDG_STATE_HOME:-$HOME/.local/state}/tkoc/prompt-theme"
tkoc_prompt_theme_name="arch"
[[ -r "$tkoc_prompt_theme_file" ]] && tkoc_prompt_theme_name="$(<"$tkoc_prompt_theme_file")"
tkoc_prompt_theme_conf="${XDG_CONFIG_HOME:-$HOME/.config}/tkoc/dotfiles/prompt-themes/$tkoc_prompt_theme_name.conf"

if [[ -r "$tkoc_prompt_theme_conf" ]]; then
    while IFS='=' read -r tkoc_pt_key tkoc_pt_value; do
        tkoc_pt_key="${tkoc_pt_key%%[[:space:]]*}"
        [[ -z "$tkoc_pt_key" || "$tkoc_pt_key" == \#* ]] && continue
        tkoc_pt_value="${tkoc_pt_value#"${tkoc_pt_value%%[![:space:]]*}"}"
        printf -v "$tkoc_pt_key" '%s' "$tkoc_pt_value"
    done <"$tkoc_prompt_theme_conf"
fi
unset -v tkoc_prompt_theme_file tkoc_prompt_theme_name tkoc_prompt_theme_conf tkoc_pt_key tkoc_pt_value
