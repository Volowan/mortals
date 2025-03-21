start_local_cdk()
{
    local help_msg="Usage:
  start_local_cdk [OPTIONS]
  start_local_cdk -h | --help
Options:
  -o, --open        Open the browser after starting the local CDK server.

This script starts the local CDK server for molecule depiction."

    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "$help_msg"
        return 0
    fi

    local open_browser=false

    while (( "$#" )); do
        case "$1" in
            -o|--open)
                open_browser=true
                shift
                ;;
            *)
                echo "Unknown flag: $1" >&2
                return 1
                ;;
        esac
    done

    if pgrep -f "cdkdepict-webapp" > /dev/null; then
        if [ "$open_browser" = false ]; then
            echo "\033[1;30mLocal CDK is already running at http://localhost:8081/depict.html\033[0m"
            return 0
        fi
    else
        echo "\033[1;33mLocal CDK was not running, initializing it at http://localhost:8081/depict.html...\033[0m"
        (nohup java -Dserver.port=8081 -jar $PATH_CDK_SNAPSHOT &> /dev/null &)
        # Wait for the server to start by pinging it
        local max_attempts=100
        local current_attempt=0
        while ! curl -s "http://localhost:8081/depict.html" > /dev/null; do
            sleep 0.1
            current_attempt=$((current_attempt+1))
            if [ $current_attempt -eq $max_attempts ]; then
                echo "\033[1;31mCDK failed to initialize.\033[0m"
                return 1
            fi
        done
        echo "\033[1;32mCDK initialized successfully.\033[0m"
    fi
    if [ "$open_browser" = true ]; then
        (nohup xdg-open "http://localhost:8081/depict.html" >/dev/null 2>&1 &)
    fi
    return 0
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
    local timeout=5


    # Make the HTTP GET request and decode URL-encoded characters
    local response=$(curl -s -f --max-time $timeout "$url")
    # Check if the response is empty
    
    if [ $? -ne 0 ]; then
        # write in red
        echo -e "\033[1;31mError: No response from the CACTUS API. Using STOUT ml model instead.\033[0m"
        smiles_to_iupac_stout "$smiles"
    elif [ -z "$response" ]; then
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
    var="import os; os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'; from STOUT import translate_forward; print(translate_forward(\"""$@""\"))"; python -c "$var"
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
  -i, --idx         Set annotation to index, [default: off].
  -mi, --mappedidx  Set annotation to mapping index, [default: off].
  -a, --abbr        Set abbreviation mode to abbreviated [default: off].
  -z, --zoom        Set zoom level, requires a value [default: 4].
  -w, --width       Set image width, requires a value and needs for height to be set too. [default: -1].
  -h, --height      Set image height, requires a value and needs for width to be set too. [default: -1].
  -t, --type        Set the type of depiction, (cob for ColorOnBlack, bot for BlackOnTransparent, cow for ColorOnWhite, etc.) [default: cow].
  -r, --rotation    Set the rotation angle in degrees, requires a value [default: 0].
  --sma             Set the a smarts pattern to match.
  --svg             Set the image format to SVG [default: PNG].

This script fetches and displays a molecule image based on SMILES input."
    
    if ! pgrep -f "cdkdepict-webapp" > /dev/null; then
        start_local_cdk
    fi


    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "$help_msg"
        return 0
    fi

    if [ -z "$1" ]; then
        # No argument provided, read from stdin, useful for piping
        while IFS= read -r line; do
            local smi="$line"
        done
    else
        # Argument provided, process as before
        all_args=("$@")
        local smi="$1"
        shift
    fi

    local annotate="none"
    local hdisp="bridgehead"
    local zoom=4
    local width=-1
    local height=-1
    local abbr="off"
    local type="cow"
    local rotation=0
    local image_format="png"
    local smart=""
    
    # Check for flags
    while (( "$#" )); do
        case "$1" in
            -m|--mapped)
                annotate="colmap"
                type="bow"
                shift
                ;;
            -i|--idx)
                annotate="number"
                shift
                ;;
            -mi|--mappedidx)
                annotate="mapidx"
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
            --sma)
                type="bow"
                smart="$2"
                shift 2
                ;;
            *)
                echo "\033[1;31mUnknown flag: $1\033[0m"
                return 1
                ;;
        esac
    done

    # Create the output directory if it doesn't exist
    mkdir -p "/tmp/molecule_preview"

    echo "$smi" | while IFS= read -r line
    do
        local smi_encoded=$(echo -n "$line" | jq -sRr @uri)
        local sma_encoded=$(echo -n "$smart" | jq -sRr @uri)
        local safe_smi=$(echo "$line" | sed 's/[\/@ ]/_/g')
        local name_hash=$(echo "$line$annotate$hdisp$zoom$width$height$abbr$type$rotation$smart" | sha256sum | cut -c1-24)


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
            --data "sma=$sma_encoded" \
            --output "$temp_file" \
            --silent

        # Check if the image was fetched successfully
        if ! check_valid_cdk_image "$temp_file"; then
            echo "Error: Invalid SMILES string received for $smi_encoded" >&2
            rm "$temp_file"
        else
            mv "$temp_file" "$outfile"
            cp "$outfile" "/tmp/molecule_preview/last.$image_format"
            command=(feh "$outfile")
            # But make it run in the background and
            # as silent as possible
            (nohup $command > /dev/null 2>&1 &)
        fi
    done
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
  --preset           Add a preset on top of chimera_base_config.cxc [default: None] (only base_config).
  --turns            Set the number of turns to make in the movie [default: 1].
  --optimization     Show the optimization of the molecule in the movie, need either two files or a log file with multiple structures.
  
This script takes p pictures with a degrees rotation interval of a molecule in 3D using ChimeraX"

    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "$help_msg"
        return 0
    fi

    local output_folder="/tmp/chimerax_snapshots"
    local name=$(basename "$input_file" | cut -d. -f1)
    local angle=30
    local angle_given=false
    local n_pictures=12
    local n_pictures_given=false
    local width=1920
    local height=1080
    local axis="y"
    local movie=true
    local preset="$PATH_MORTALS/chimera_base_config.cxc"
    local turns=1
    local optimization=false

    local input_files=""
    local number_input_files=0

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
            --preset)
                # add the preset to preset with a space
                preset="$preset $2"
                shift 2
                ;;
            --turns)
                turns="$2"
                shift 2
                ;;
            --optimization)
                optimization=true
                shift
                ;;
            *)
                if [ $number_input_files -eq 0 ]; then
                    input_files="$1"
                    number_input_files=1
                else
                    input_files="$input_files $1"
                    number_input_files=$((number_input_files+1))
                fi
                shift
                ;;
        esac
    done

    # Main input file is the realpath of the first input file
    input_file=$(realpath $(echo "$input_files" | cut -d" " -f1))
    local input_extension=$(basename "$input_file" | cut -d. -f2)
    # Need check that all extensions of files are the same
    local input_is_log=$(echo "$input_extension" | grep -i "log")

    echo "Input extension is $input_extension"
    echo "Inputs are $input_files"
    echo "Input file is $input_file"

    if [ $number_input_files -eq 0 ]; then
        echo "Error: No input file provided" >&2
        return 1
    fi

    # If user asks for optimization, check for .log or two files
    # In the future, this could be extended to multiple files one after the other
    if [ "$optimization" = true ]; then
        if [ "$input_is_log" = false ] && [ $number_input_files -ne 2 ]; then
            echo "Error: Need exactly 2 files for optimization, $number_input_files detected" >&2 
            return 1
        elif [ "$input_is_log" = true ] && [ $number_input_files -ne 2 ]; then
            echo "Error: Need exactly 1 log file for optimization for the moment" >&2
            return 1
        fi
    else
        if [ $number_input_files -ne 1 ]; then
            echo "Error: Need exactly 1 file when not dealing with an optimization, $number_input_files detected" >&2
            return 1
        fi
    fi

    # Safely create the output folder
    mkdir -p "$output_folder"
    
    # If the angle is not given but the number of pictures is, calculate the angle
    if [ "$n_pictures_given" = true ] && [ "$angle_given" = false ]; then
        # Total angle is 360*turns
        local total_angle=$((360*$turns))
        angle=$(printf "%.0f" $(echo "$total_angle/$n_pictures" | bc -l))
    fi

    if [ "$n_pictures_given" = false ] && [ "$angle_given" = true ]; then
        n_pictures=$(printf "%.0f" $(echo "$total_angle/$angle" | bc)) # No -l to round down
    fi


    if [ "$optimization" = true ] && ! [ "$input_is_log" ]; then
        input_file_2=$(realpath $(echo "$input_files" | cut -d" " -f2))
    fi

    # Create the script file:
    local script_file="/tmp/chimera_script.cxc"
    echo "windowsize $width $height" > "$script_file"
    echo "open $input_file" >> "$script_file"
    # open each preset
    for i in $preset; do
        echo "open $i" >> "$script_file"
    done
    echo "open $PATH_MORTALS/chimera_reframe.cxc" >> "$script_file"

    echo "n_pictures: $n_pictures"
    for i in $(seq 0 $((n_pictures-1))); do
        formatted_i=$(printf "%03d" $i)
        echo "save $output_folder/${name}_${formatted_i}.png" >> "$script_file"
        echo "turn $axis $angle 1" >> "$script_file"
        echo "wait 1" >> "$script_file"
    done
    if [ "$movie" = true ]; then
        echo "movie record" >> "$script_file"
        if [ "$optimization" = true ]; then
            if [ "$input_is_log" ]; then
                echo "recognizing log file"
                echo "open $input_file" >> "$script_file" # I open it twice to create a nice morphing effect
                for i in $preset; do
                    echo "open $i" >> "$script_file"
                done
                echo "hide #2" >> "$script_file"
                echo "coordset #1 1" >> "$script_file"
                echo "morph #1 #2 frames 50" >> "$script_file"
                echo "wait 50" >> "$script_file"
                echo "delete #2" >> "$script_file" # Should not impact the visual, and improves performance slightly
            elif [ "$input_extension" = "cif" ]; then
                # Align cifs
                echo "I recognized cif here I would align the two files"
                echo "open $input_file_2" >> "$script_file"
                echo "morph #2 #1 frames 50" >> "$script_file"
                echo "hide #1" >> "$script_file"
                echo "hide #2" >> "$script_file"
                echo "bond #3" >> "$script_file"
                for i in $preset; do
                    echo "open $i" >> "$script_file"
                done
                echo "wait 50" >> "$script_file"
                echo "delete #1" >> "$script_file"
                echo "delete #2" >> "$script_file"

                for i in $preset; do
                    echo "open $i" >> "$script_file"
                done
            else
                echo "open $input_file_2" >> "$script_file"
                for i in $preset; do
                    echo "open $i" >> "$script_file"
                done
                echo "hide #2" >> "$script_file"
                echo "morph #2 #1 frames 50" >> "$script_file"
                echo "wait 50" >> "$script_file"
                echo "delete #2" >> "$script_file"
            fi
        fi
        echo "turn y 0 25" >> "$script_file" # Not the cleanest, but wait 25 frames
        echo "wait 25" >> "$script_file"
        echo "turn y 2 $((180*turns))" >> "$script_file"
        echo "wait $((180*turns))" >> "$script_file"
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

one_snapshot_3d() {
    local help_msg="Usage:
    one_snapshot_3d INPUT_FILE PRESET OUTPUT_FILE
    one_snapshot_3d -h | --help"

    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "$help_msg"
        return 0
    fi
    
    local input_file=$1
    local preset=$2
    local output_file=$3
    
    local script_file="/tmp/chimera_script.cxc"
    echo "windowsize 1920 1080" > "$script_file"
    echo "open $input_file" >> "$script_file"
    echo "open $preset" >> "$script_file"
    echo "save $output_file" >> "$script_file"

    command="chimerax --offscreen --script $script_file --exit --silent"
    eval "$command"
}

show_chimerax_3d(){

    files_to_open=""
    preset="$PATH_MORTALS/chimera_base_config_human.cxc"

    while (( "$#" )); do
        case "$1" in
            -p|--preset)
                # add the preset to preset with a space
                preset="$preset $2"
                shift 2
                ;;
            *)
                # Check if file variable is empty
                if [ -z "$files_to_open" ]; then
                    files_to_open="$1"
                else
                    files_to_open="$files_to_open $1"
                fi
                shift
                ;;
        esac
    done

    echo "Opening the following files in chimerax: $files_to_open"
    echo "Using the following preset: $preset"

    # Open the files in chimerax
    local command="(nohup chimerax $files_to_open $preset >/dev/null 2>&1 &)"
    eval "$command"
}
