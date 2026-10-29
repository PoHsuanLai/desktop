# The desktop. Every part is a repo checked out beside this one (~/sill, ~/detent, ...).
#
#   just              build and install everything
#   just build        build everything, as you
#   just only sill detent   build and install just these parts
#   just check        what this machine lacks, with the line that installs it
#
# One line per part; the whole output is in ~/.local/state/desktop-install.log.

export PREFIX := env("PREFIX", "/usr/local")

# build and install everything
install:
    install/plain.sh install

# build everything, as you
build:
    install/plain.sh build

# build and install just these parts
only +parts:
    install/plain.sh install {{parts}}

# what this machine lacks
check:
    ./install.sh --check

# every part, in install order
parts:
    @echo callers porter steward stoker almanac docket cua detent casement sill transom turnstile keycap anyview mailo files palmrest session
