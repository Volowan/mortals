source "$PATH_MORTALS/mortals_functions.sh"

alias cdk="start_local_cdk"
alias show_mol="fetch_image_cdk"
alias show_mol_3d='chimera_show() {(nohup chimerax "$@" $PATH_MORTALS/chimera_base_config_human.cxc >/dev/null 2>&1 &); unset -f chimera_show;}; chimera_show'
alias snapshot_3d='snapshot_3d'
alias iupac="smiles_to_iupac"
alias iupac_ml="smiles_to_iupac_stout"
alias opsin="opsin_name_to_smiles"
alias show_opsin="fetch_image_cdk_name"

if $MORTALS_SHORT_ALIASES; then
    alias sm="fetch_image_cdk" #Shortcut for show_mol
    alias sm3='chimera_show() {(nohup chimerax "$@" $PATH_MORTALS/chimera_base_config_human.cxc >/dev/null 2>&1 &); unset -f chimera_show;}; chimera_show' #Shortcut for show_mol_3d
    alias so="fetch_image_cdk_name" #Shortcut for show_opsin
fi
