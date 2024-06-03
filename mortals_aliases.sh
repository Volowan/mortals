source "$PATH_MORTALS/mortals_functions.sh"

alias cdk="start_local_cdk"
alias show_mol="fetch_image_cdk"
alias iupac="smiles_to_iupac"
alias iupac_ml="smiles_to_iupac_stout"
alias opsin="opsin_name_to_smiles"
alias show_opsin="fetch_image_cdk_name"

if $MORTALS_SHORT_ALIASES; then
    alias sm="fetch_image_cdk" #Shortcut for show_mol
    alias so="fetch_image_cdk_name" #Shortcut for show_opsin
fi
