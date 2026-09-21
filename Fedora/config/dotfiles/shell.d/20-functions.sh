# tkoc: managed shell functions.
mkcd() {
    mkdir -p -- "$1" && cd -- "$1"
}
