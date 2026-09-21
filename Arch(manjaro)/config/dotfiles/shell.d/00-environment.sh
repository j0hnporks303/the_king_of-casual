# tkoc: load managed environment variables from environment.conf.
tkoc_env_file="${XDG_CONFIG_HOME:-$HOME/.config}/tkoc/dotfiles/environment.conf"
if [[ -r "$tkoc_env_file" ]]; then
    while IFS='=' read -r tkoc_env_key tkoc_env_value; do
        [[ "$tkoc_env_key" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        tkoc_env_key="${tkoc_env_key%%[[:space:]]*}"
        tkoc_env_value="${tkoc_env_value#"${tkoc_env_value%%[![:space:]]*}"}"
        export "$tkoc_env_key=$tkoc_env_value"
    done <"$tkoc_env_file"
fi
unset -v tkoc_env_file tkoc_env_key tkoc_env_value
