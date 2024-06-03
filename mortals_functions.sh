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
    mamba activate STOUT
    var="import os; os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'; from STOUT import translate_forward; print(translate_forward(\"""$@""\"))"; python -c "$var"
    mamba deactivate
}

opsin_name_to_smiles() {
    #local name="$1"
    mamba activate STOUT
    # Translate the following python script
    # from py2opsin import py2opsin
    # print(py2opsin(chemical_name="name", output_format="SMILES"))
    
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

    #echo "Name: $name"

    var="from py2opsin import py2opsin; print(py2opsin(chemical_name=\"""$name""\", output_format='SMILES'))"; python -c "$var"
    mamba deactivate
}

fetch_image_cdk() {
    # Help message
    local help_msg="Usage: fetch_image_cdk SMILES_STRING [OPTIONS]
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
    
    # Check if cdk app is initialized
    # if ! pgrep -f 'dynamic_wallpaper.sh' > /dev/null; then
    #     (nohup ~/bash_scripts/dynamic_wallpaper.sh &>/dev/null &)
    # fi

    if ! pgrep -f "cdkdepict-webapp" > /dev/null; then
        echo "\033[1;33mLocal CDK was not running, initializing it...\033[0m"
        (nohup java -Dserver.port=8081 -jar  ~/Documents/liac/cdk_depict/cdkdepict-webapp/target/cdkdepict-webapp-1.11-SNAPSHOT.war &> /dev/null &)
        local correclty_initialized=false
        for i in {1..20}
        do
            sleep 0.1
            if pgrep -f "cdkdepict-webapp" > /dev/null; then
                echo "\033[1;32mCDK initialized successfully.\033[0m"
                correclty_initialized=true
                break
            fi
        done
        if [ "$correclty_initialized" = false ]; then
            echo "\033[1;31mCDK failed to initialize.\033[0m"
            return 1
        fi
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

    local help_msg="Usage: fetch_image_cdk_name IUPAC_OR_COMMON_NAME [OPTIONS]
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
