#!/bin/sh
# install.sh -- sets up the R Notebook plugin for Tern, from this folder.
#
#   ./install.sh           check R and its packages, then install the plugin
#   ./install.sh --link    use this folder in place instead of a copy (development)
#   ./install.sh --yes     answer yes to every question (unattended installs)
#
# R packages go to your personal R library; nothing here needs root.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
link=no
yes=no
for arg in "$@"; do
	case $arg in
	--link) link=yes ;;
	--yes | -y) yes=yes ;;
	-h | --help)
		sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "install.sh: unknown option '$arg' (try --help)" >&2
		exit 2
		;;
	esac
done

fail() {
	printf '\nerror: %s\n' "$*" >&2
	exit 1
}

# ask QUESTION -> success when the answer is yes (Enter means yes)
ask() {
	[ "$yes" = yes ] && return 0
	printf '%s [Y/n] ' "$1"
	read -r answer || answer=n
	case $answer in [Nn]*) return 1 ;; *) return 0 ;; esac
}

case $(uname -s) in
Linux | Darwin) ;;
*) fail "R Notebook runs chunks on Linux and macOS (on Windows, use Tern inside WSL)." ;;
esac
command -v tern >/dev/null 2>&1 ||
	fail "Tern isn't installed, or 'tern' isn't on your PATH."
command -v Rscript >/dev/null 2>&1 ||
	fail "R isn't installed (there is no 'Rscript' on your PATH). Get R from https://cloud.r-project.org, then run this again."

echo "Checking R ..."
if ! Rscript "$here/deps.R"; then
	echo
	if ask "Install the missing R packages now?"; then
		Rscript "$here/deps.R" --install || fail "Installing the R packages failed; the messages above say why."
	else
		fail "The notebook can't run chunks without them. Install them later with: Rscript '$here/deps.R' --install"
	fi
fi
if ! Rscript -e 'quit(status = !requireNamespace("rmarkdown", quietly = TRUE))' >/dev/null 2>&1; then
	echo
	if ask "HTML (knitting, and the notebook's .nb.html) needs the rmarkdown package, a larger download. Install it too?"; then
		Rscript "$here/deps.R" --install --knit || echo "rmarkdown didn't install; making HTML will tell you what's missing."
	fi
fi

echo
if [ "$link" = yes ]; then
	tern plugin link "$here"
elif ! tern plugin install "$here" --force; then
	fail "Tern couldn't install the plugin. If R Notebook is linked from another folder, run 'tern plugin unlink rmd' first, or use ./install.sh --link."
fi

cat <<'EOF'

All set. Open any .Rmd file in Tern, for example:

    tern open homework.Rmd

then press Shift+Enter in a chunk to run it (R starts on the first run).
Press ? in the notebook for every shortcut.
EOF
