# bash completion for bwssh.  Source it, or install to
# ~/.local/share/bash-completion/completions/bwssh (bwssh install does this).
_bwssh() {
  local cur prev cmds
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmds="install windows setup-cli login lock add-host remove-host list-hosts sync-hosts status doctor uninstall version help"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    add-host|remove-host)
      if [[ "$cur" != -* ]]; then
        local hosts="${HOME}/.ssh/bwSshBridgeHosts.conf"
        if [[ -f "$hosts" ]]; then
          local aliases
          aliases="$(awk '$1=="Host"{for(i=2;i<=NF;i++) print $i}' "$hosts")"
          COMPREPLY=( $(compgen -W "$aliases" -- "$cur") )
        fi
      elif [[ "${COMP_WORDS[1]}" == add-host ]]; then
        COMPREPLY=( $(compgen -W "--alias-only --use-key" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "--delete-key" -- "$cur") )
      fi
      ;;
    install)
      COMPREPLY=( $(compgen -W "--no-cli --no-windows --copy" -- "$cur") )
      ;;
    setup-cli)
      COMPREPLY=( $(compgen -W "--force" -- "$cur") )
      ;;
    sync-hosts)
      COMPREPLY=( $(compgen -W "--push" -- "$cur") )
      ;;
    status|doctor)
      COMPREPLY=( $(compgen -W "--windows" -- "$cur") )
      ;;
  esac
  return 0
}
complete -F _bwssh bwssh
