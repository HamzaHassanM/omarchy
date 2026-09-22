echo "Install Elsewhen, the world clock plugin"

omarchy-pkg-add elsewhen

packaged_plugin="/usr/share/omarchy/shell/plugins/omacom.elsewhen"
user_plugin="$HOME/.config/omarchy/plugins/omacom.elsewhen"

# The package moved from plugins/ to shell/plugins/ once, stranding the link an
# earlier run made to the old path. A link the user made is left alone.
if [[ -L $user_plugin && ! -e $user_plugin && $(readlink "$user_plugin") == /usr/share/omarchy/* && -d $packaged_plugin ]]; then
  ln -sfn "$packaged_plugin" "$user_plugin"
fi

# Dev link/unlink takes effect next login; IPC must reach the current session.
session_omarchy_path=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1) || true
: "${session_omarchy_path:=$OMARCHY_PATH}"

# Both the current and next session must be able to discover packaged plugins.
if [[ ( ! $OMARCHY_PATH -ef /usr/share/omarchy || ! $session_omarchy_path -ef /usr/share/omarchy ) && -d $packaged_plugin && ! -e $user_plugin && ! -L $user_plugin ]]; then
  mkdir -p "${user_plugin%/*}"
  ln -s "$packaged_plugin" "$user_plugin"
fi

OMARCHY_PATH="$session_omarchy_path" omarchy-shell -q shell rescanPlugins
OMARCHY_PATH="$session_omarchy_path" omarchy-bar put omacom.elsewhen --before omarchy.clock
