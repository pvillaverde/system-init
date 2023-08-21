alias dc="docker-compose"
# Timestamp on history
HISTTIMEFORMAT="%d/%m/%y %T "
HISTTIMEFORMAT="%F %T "
# https://github.com/junegunn/fzf
if [ -d "/usr/share/doc/fzf/examples/" ]; then
	source /usr/share/doc/fzf/examples/key-bindings.bash
	#source /usr/share/doc/fzf/examples/completion.bash
fi

# powerline-go
if [ -x /usr/local/bin/powerline-go ]; then
	export COLUMNS=$COLUMNS
	export PRIORITY=venv,git-status,git-branch,exit,host,ssh,perms,hg,jobs,cwd-path
	export MODULES=venv,user,shell-var,aws,host,ssh,cwd,perms,git,hg,jobs,exit,root

	function _update_ps1() {
		PS1=$(/usr/local/bin/powerline-go -modules ${MODULES} -colorize-hostname -error "${?}" -shell bash -priority "${PRIORITY}" 2>/dev/null)
	}

	PROMPT_COMMAND='echo -ne "\033]0;${USER}@${HOSTNAME}: ${PWD}\007"'
	if [ "$TERM" != "linux" ]; then
		PROMPT_COMMAND="_update_ps1; $PROMPT_COMMAND"
	fi

fi
