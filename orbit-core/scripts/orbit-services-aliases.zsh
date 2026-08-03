# ORBIT core + MLX — short commands for zsh.
#
# Add once to ~/.zshrc (use your real path if the repo moves):
#   source "/Users/ayush/Documents/PJ/ORBIT/orbit-core/scripts/orbit-services-aliases.zsh"
#
# Then in any terminal:
#   orbit-up | orbit-down | orbit-status | orbit-restart
#   orbit-up-dev   # same as orbit-services.sh --dev start

emulate -L zsh
[[ -o interactive ]] || return 0

# Path is fixed at source time; functions call it when you run orbit-*.
_ORBIT_SERVICES_SCRIPT="${0:A:h}/orbit-services.sh"

orbit-up() { "$_ORBIT_SERVICES_SCRIPT" start "$@" }
orbit-up-dev() { "$_ORBIT_SERVICES_SCRIPT" --dev start "$@" }
orbit-down() { "$_ORBIT_SERVICES_SCRIPT" stop "$@" }
orbit-restart() { "$_ORBIT_SERVICES_SCRIPT" restart "$@" }
orbit-status() { "$_ORBIT_SERVICES_SCRIPT" status "$@" }
