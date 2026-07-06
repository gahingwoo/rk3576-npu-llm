# Kiln: welcome banner on interactive console login. Lists the NPU commands
# instead of dropping straight into a chat. Disable with /etc/kiln-no-motd.
case "$-" in
	*i*)
		if [ -z "$KILN_MOTD" ] && [ ! -e /etc/kiln-no-motd ] && [ -t 1 ]; then
			export KILN_MOTD=1   # print once, not from sub-shells
			printf '\n'
			printf '  ==================================================================\n'
			printf '   Kiln  -  LLM + vision on the RK3576 NPU  (mainline kernel)\n'
			printf '  ==================================================================\n'
			printf '   kiln-chat             chat with an LLM on the NPU  (Qwen2.5-1.5B)\n'
			printf '   kiln-vision <img>     classify an image on the NPU (MobileNet)\n'
			printf '                         e.g.  kiln-vision /opt/models/test.jpg\n'
			printf '  ==================================================================\n\n'
		fi
		;;
esac
