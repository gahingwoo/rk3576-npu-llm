# Kiln install-status MOTD. Sourced at interactive login (/etc/profile.d). Reports
# the outcome of the automatic phase-2 install: a one-time welcome on success, and
# a persistent pointer to the log on failure (until the operator clears it). Kept
# tiny and side-effect-free -- it is SOURCED, so it must never `exit` the shell.
case "$-" in *i*) ;; *) return 2>/dev/null || true ;; esac   # interactive shells only

if [ -f /etc/kiln/phase2-failed ]; then
	printf '\n\033[1;31m[Kiln]\033[0m phase 2 install FAILED. See \033[1m/var/log/kiln-phase2.log\033[0m,\n'
	printf '       then re-run:  \033[1msudo bash /opt/kiln/scripts/kiln-install.sh\033[0m  (runs offline)\n\n'
elif [ -f /etc/kiln/phase2-done ] && { [ ! -f "$HOME/.kiln-welcomed" ] || [ /etc/kiln/phase2-done -nt "$HOME/.kiln-welcomed" ]; }; then
	# Show once per install. `-nt` re-shows after a fresh (re)install writes a newer
	# phase2-done, even if an old welcomed-flag exists (e.g. one set on the pre-reboot
	# boot before the login gate landed).
	printf '\n\033[1;36m[Kiln]\033[0m installed \342\234\223  LLM + vision on the RK3576 NPU.\n'
	printf '       try:  \033[1mkiln-chat\033[0m   \033[1mkiln-vision /opt/models/test.jpg\033[0m   \033[1mkiln-config\033[0m\n'
	printf '       health check:  \033[1mkiln-doctor\033[0m\n\n'
	: > "$HOME/.kiln-welcomed" 2>/dev/null || true
fi
