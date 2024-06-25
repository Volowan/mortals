start_local_cdk()
{
    if pgrep -f "cdkdepict-webapp" > /dev/null; then
        echo "\033[1;30mLocal CDK is already running at http://localhost:8081/depict.html\033[0m"
        return 0
    else
        (nohup java -Dserver.port=8081 -jar $PATH_CDK_SNAPSHOT &> /dev/null &)
        echo "\033[1;30mLocal CDK started at http://localhost:8081/depict.html\033[0m"
    fi
}

check_valid_cdk_image () {
    
    local image_path="$1"

    if [ -z "$image_path" ]; then
        #echo "Error: No image path provided" >&2
        return 1
    fi

    # Try to read dimensions, capture errors
    if ! identify -format "%w %h" "$image_path" >/dev/null 2>&1; then # Put in /dev/null to suppress error message
        #echo "Error: Invalid image file" >&2
        return 1  # Return with error
    fi

    # If the image is valid, read the dimensions
    read width height  < <(identify -format "%w %h" "$image_path")

    if [ "$width" -ge 9 ] && [ "$height" -ge 9 ]; then # Even the smallest valid image is 9x9, and an error is 8x8
        return 0
    else
        #echo "Error: Invalid image dimensions width=$width and height=$height" >&2
        return 1
    fi
}

# Function to convert SMILES to IUPAC name using the CACTUS API and STOUT ML model
smiles_to_iupac() {

    if [ -z "$1" ]; then
        # No argument provided, read from stdin, useful for piping
        while IFS= read -r line; do
            local smiles="$line"
        done
    else
        # Argument provided, process as before
        local smiles="$1"
    fi

    local rep="iupac_name"
    local url="https://cactus.nci.nih.gov/chemical/structure/${smiles}/${rep}"

    # Make the HTTP GET request and decode URL-encoded characters
    local response=$(curl -s -f "$url")
    # Check if the response is empty
    if [ -z "$response" ]; then
        # Call the fallback function if no response
        echo -e "\033[1;33mNo response from the CACTUS API. Using STOUT ml model instead.\033[0m"
        smiles_to_iupac_stout "$smiles"
    else
        # Print the decoded response
        decoded_response=$(echo -e "${response//%/\\x}")

        # Make every alpha character lowercase
        decoded_response=$(echo "$decoded_response" | tr '[:upper:]' '[:lower:]')
        # If first is a letter, make it uppercase
        decoded_response=$(echo "$decoded_response" | sed -r 's/([a-z])/\U\1/' )
        echo "$decoded_response"
    fi
}

smiles_to_iupac_stout() {
    mamba activate mortals
    var="import os; os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'; from STOUT import translate_forward; print(translate_forward(\"""$@""\"))"; python -c "$var"
    mamba deactivate
}

opsin_name_to_smiles() {
    mamba activate mortals

    local name=""
    while (( "$#" )); do
        # If the argument is not a pipe
        if [[ "$1" != "|" ]]; then
            name+="$1 "
            shift
        else
            break
        fi
    done

    var="from py2opsin import py2opsin; print(py2opsin(chemical_name=\"""$name""\", output_format='SMILES'))"; python -c "$var"
    mamba deactivate
}

fetch_image_cdk() {
    # Help message
    local help_msg="Usage:
  fetch_image_cdk SMILES_STRING [OPTIONS]
  fetch_image_cdk -h | --help

Options:
  -m, --mapped      Set annotation to colormap, [default: off].
  -a, --abbr        Set abbreviation mode to abbreviated [default: off].
  -z, --zoom        Set zoom level, requires a value [default: 4].
  -w, --width       Set image width, requires a value and needs for height to be set too. [default: -1].
  -h, --height      Set image height, requires a value and needs for width to be set too. [default: -1].
  -t, --type        Set the type of depiction, (cob for ColorOnBlack, bot for BlackOnTransparent, cow for ColorOnWhite, etc.) [default: cow].
  -r, --rotation    Set the rotation angle in degrees, requires a value [default: 0].
  --svg             Set the image format to SVG [default: PNG].

This script fetches and displays a molecule image based on SMILES input."
    
    if ! pgrep -f "cdkdepict-webapp" > /dev/null; then
        echo "\033[1;33mLocal CDK was not running, initializing it...\033[0m"
        (nohup java -Dserver.port=8081 -jar  ~/Documents/liac/cdk_depict/cdkdepict-webapp/target/cdkdepict-webapp-1.11-SNAPSHOT.war &> /dev/null &)
        local correclty_initialized=false
        for i in {1..20}
        do
            sleep 0.1
            if pgrep -f "cdkdepict-webapp" > /dev/null; then
                correclty_initialized=true
                break
            fi
        done
        if [ "$correclty_initialized" = false ]; then
            echo "\033[1;31mCDK failed to initialize.\033[0m"
            return 1
        fi
        sleep 3
        echo "\033[1;32mCDK initialized successfully.\033[0m"
    fi


    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "$help_msg"
        return 0
    fi

    local all_args=("$@")
    local smi=$1
    shift
    smi_encoded=$(echo -n "$smi" | jq -sRr @uri)
    local safe_smi=$(echo "$smi" | sed 's/[\/@ ]/_/g')
    local name_hash=$(echo "$all_args" | sha256sum | cut -c1-24)
    local annotate="none"
    local hdisp="bridgehead"
    local zoom=4
    local width=-1
    local height=-1
    local abbr="off"
    local type="cow"
    local rotation=0
    local image_format="png"
    
    # Check for flags
    while (( "$#" )); do
        case "$1" in
            -m|--mapped)
                annotate="colmap"
                type="bow"
                shift
                ;;
            -a|--abbr)
                abbr="on"
                shift
                ;;
            -z|--zoom)
                zoom="$2"
                shift 2
                ;;
            -w|--width)
                width="$2"
                shift 2
                ;;
            -h|--height)
                height="$2"
                shift 2
                ;;
            -r|--rotation)
                rotation="$2"
                shift 2
                ;;
            -t|--type)
                type="$2"
                shift 2
                ;;
            --svg)
                image_format="svg"
                shift
                ;;
            *)
                echo "\033[1;31mUnknown flag: $1\033[0m"
                return 1
                ;;
        esac
    done

    # Create the output directory if it doesn't exist
    mkdir -p "/tmp/molecule_preview"

    local temp_file=$(mktemp)
    local outfile="/tmp/molecule_preview/"$name_hash".$image_format"
    
    # Use curl to make the HTTP GET request
    local url="http://localhost:8081/depict/$type/$image_format"
    #-H "Accept: image/$image_format" \
    curl -G "$url" \
        --data "smi=$smi_encoded" \
        --data "w=$width" \
        --data "h=$height" \
        --data "abbr=$abbr" \
        --data "hdisp=$hdisp" \
        --data "zoom=$zoom" \
        --data "annotate=$annotate" \
        --data "r=$rotation" \
        --output "$temp_file" \
        --silent

    # Check if the image was fetched successfully
    if ! check_valid_cdk_image "$temp_file"; then
        echo "Error: Invalid SMILES string received for $smi_encoded" >&2
        rm "$temp_file"
    else
        mv "$temp_file" "$outfile"
        command=(feh "$outfile")
        # But make it run in the background and
        # as silent as possible
        (nohup $command > /dev/null 2>&1 &)
    fi
}

fetch_image_cdk_name () {

    local help_msg="Usage:
  fetch_image_cdk_name IUPAC_OR_COMMON_NAME [OPTIONS]
  fetch_image_cdk_name -h | --help

Options:
  -m, --mapped      Set annotation to colormap, [default: off].
  -a, --abbr        Set abbreviation mode to abbreviated [default: off].
  -z, --zoom        Set zoom level, requires a value [default: 4].
  -w, --width       Set image width, requires a value and needs for height to be set too. [default: -1].
  -h, --height      Set image height, requires a value and needs for width to be set too. [default: -1].
  -t, --type        Set the type of depiction, (cob for ColorOnBlack, bot for BlackOnTransparent, cow for ColorOnWhite, etc.) [default: cow].
  -r, --rotation    Set the rotation angle in degrees, requires a value [default: 0].
  --svg             Set the image format to SVG [default: PNG].

This script fetches and displays a molecule image based on its common or iupac name."
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "$help_msg"
        return 0
    fi
    local full_name=""
    while (( "$#" )); do
        # If the argument is not a flag
        if [[ "$1" != -* ]]; then
            full_name+="$1 "
            shift
        else
            break
        fi
    done

    local smiles=$(opsin_name_to_smiles "${full_name}")

    fetch_image_cdk "$smiles" "${@}"
}

smiles_to_3d_structure() {
    mamba activate mortals
    
    local smi=$1
    local python_code="from rdkit.Chem.AllChem import EmbedMolecule; from rdkit.Chem import MolFromSmiles, AddHs, MolToXYZBlock; mol = MolFromSmiles(\"$smi\"); mol = AddHs(mol); EmbedMolecule(mol); print(MolToXYZBlock(mol))"
    python -c "$python_code" > /tmp/3d_structure.xyz

    mamba deactivate
}

snapshot_3d() {
    local help_msg="Usage:
  rotation_3d_pictures INPUT_FILE [OPTIONS]
  rotation_3d_pictures -h | --help

Options:
  -o, --output       Set the output folder, requires a value [default: /tmp/chimerax_snapshots].
  -n, --name         Set a custom name for the molecule, requires a value [default: INPUT_FILE base name].
  -p, --pictures     Set the number of pictures to take, requires a value [default: floor(360/angle) or 12].
  -a, --angle        Set the angle of rotation between two pictures in degrees, requires a value [default: round(360/n_pictures) or 30].
  -w, --width        Set the width of the image, requires a value [default: 1920].
  -h, --height       Set the height of the image, requires a value [default: 1080].
  --axis             Set the axis of rotation, requires a value [default: y].
  --no-movie         Do not create an mp4 of the molecule.
  
This script takes p pictures with a degrees rotation interval of a molecule in 3D using ChimeraX"

    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "$help_msg"
        return 0
    fi

    local input_file=$(realpath "$1")
    local output_folder="/tmp/chimerax_snapshots"
    local name=$(basename "$input_file" | cut -d. -f1)
    local input_extension=$(basename "$input_file" | cut -d. -f2)
    local input_is_log=$(echo "$input_extension" | grep -i "log")
    local angle=30
    local angle_given=false
    local n_pictures=12
    local n_pictures_given=false
    local width=1920
    local height=1080
    local axis="y"
    local movie=true

    shift 1
    # Check for flags
    while (( "$#" )); do
        case "$1" in
            -n|--name)
                name="$2"
                shift 2
                ;;
            -p|--pictures)
                n_pictures="$2"
                n_pictures_given=true
                shift 2
                ;;
            -a|--angle)
                angle="$2"
                angle_given=true
                shift 2
                ;;
            -w|--width)
                width="$2"
                shift 2
                ;;
            -h|--height)
                height="$2"
                shift 2
                ;;
            -o|--output)
                output_folder=$(realpath "$2")
                shift 2
                ;;
            --axis)
                axis="$2"
                shift 2
                ;;
            --no-movie)
                movie=false
                shift
                ;;
            *)
                echo "\033[1;31mUnknown flag: $1\033[0m"
                return 1
                ;;
        esac
    done

    # Safely create the output folder
    mkdir -p "$output_folder"
    
    # If the angle is not given but the number of pictures is, calculate the angle
    if [ "$n_pictures_given" = true ] && [ "$angle_given" = false ]; then
        angle=$(printf "%.0f" $(echo "360/$n_pictures" | bc -l))
    fi

    if [ "$n_pictures_given" = false ] && [ "$angle_given" = true ]; then
        n_pictures=$(printf "%.0f" $(echo "360/$angle" | bc)) # No -l to round down
    fi

    # Create the script file:
    local script_file="/tmp/chimera_script.cxc"
    echo "windowsize $width $height" > "$script_file"
    echo "open $input_file" >> "$script_file"
    echo "open $PATH_MORTALS/chimera_base_config.cxc" >> "$script_file"
    for i in $(seq 0 $((n_pictures-1))); do
        formatted_i=$(printf "%03d" $i)
        echo "save $output_folder/${name}_${formatted_i}.png" >> "$script_file"
        echo "turn $axis $angle 1" >> "$script_file"
        echo "wait 1" >> "$script_file"
    done
    if [ "$movie" = true ]; then
        echo "movie record" >> "$script_file"
        if [ "$input_is_log" ]; then
            echo "open $input_file" >> "$script_file" # I open it twice to create a nice morphing effect
            echo "open $PATH_MORTALS/chimera_base_config.cxc" >> "$script_file"
            echo "hide #2" >> "$script_file"
            echo "coordset #1 1" >> "$script_file"
            echo "morph #1 #2 frames 50" >> "$script_file"
            echo "wait 50" >> "$script_file"
            echo "delete #2" >> "$script_file" # Should not impact the visual, and improves performance slightly
        fi
        echo "turn y 0 25" >> "$script_file" # Not the cleanest, but wait 25 frames
        echo "wait 25" >> "$script_file"
        echo "turn y 2 180" >> "$script_file"
        echo "wait 180" >> "$script_file"
        echo "movie encode $output_folder/${name}.mp4" >> "$script_file"
    fi

    # Actually run the command
    command="chimerax --offscreen --script $script_file --exit --silent"
    eval "$command"
    echo "Pictures saved in $output_folder"
    if [ "$movie" = true ]; then
        echo "Movie saved as $output_folder/${name}.mp4"
    fi
}
