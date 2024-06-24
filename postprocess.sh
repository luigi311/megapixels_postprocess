#!/usr/bin/env bash

# The post-processing script gets called after taking a burst of
# pictures into a temporary directory. The first argument is the
# directory containing the raw files in the burst. The contents
# are 1.dng, 2.dng.... up to the number of photos in the burst.
#
# The second argument is the filename for the final photo without
# the extension, like "/home/user/Pictures/IMG202104031234"
#
# The third argument is 1 or 0 for the cleanup user config. If this
# is 0 the .dng file should not be moved to the output directory
#
# The post-processing script is responsible for cleaning up
# temporary directory for the burst.

set -e

if [ "$#" -ne 3 ]; then
    printf "Usage: %s [burst-dir] [target-name] [save-dng]\n" "$0"
    exit 2
fi

# ********* User variables *********

EXTERNAL_EXTENSION="png" # Final image extension to output the final image, change to jxl/jpg/avif/webp to save space or png for lossless
IMAGE_QUALITY=90 # Quality of the final image when converting (0-100)
PARALLEL_RAW=0 # Amount of dng images to read in parallel, will max out a core so dont set this too high, 0 for auto
AUTO_WHITE_BALANCE=1 # Enable auto white balance, enable to fix color issues such as green images, set to 0 to disable, set to 1 to enable
AUTO_STACK=1 # Enable auto stacking, set to 0 to disable, set to 1 to enable
SHRINK_IMAGES=0 # Shrink images by half to speed up processing and then superresolution back up to the original size at the end
DEHAZE=0 # Flag to dehaze all images, set to 0 to disable, 1 to enable
DENOISE_ALL=0 # Flag to denoise all images, set to 0 to disable, 1 to enable
DENOISE=0 # Enable denoise, set to 0 to disable, disabled by default due to poor performance on some devices
COLOR=0 # Enable color adjustments, set to 0 to disable, set to 1 to enable
SUPER_RESOLUTION=0 # Enable Super Resolution, set to 0 to disable, set to 1 to enable
SHARPEN=1 # Enable to apply sharpening on the postprocessed image, set to 0 to disable, set to 1 to enable
SHARPEN_AMOUNT=1.0 # Amount of sharpening to apply to postprocessed image
HALF_SIZE=0 # Enable to reduce raw image size in half to speed up reading, set to 0 to disable, set to 1 to enable

# ********* End user variables *********


# Setup variables
INTERNAL_EXTENSION="png" # Image extension to use for internal outputs, recommended to use a lossless format
FORCE_CONTAINER=0 # Force the use of container, set to 0 to disable, set to 1 to enable
CONTAINER_RUNTIME="podman" # Set the container runtime to use, podman or docker
LOW_POWER_IMAGE_PROCESSING="/etc/megapixels/Low-Power-Image-Processing" # Path to check for the low power image processing repo if not using docker containers
DOCKER_IMAGE="docker.io/luigi311/low-power-image-processing:latest"
POSTPROCESS_QUEUE_FILE="/tmp/megapixels_postprocess_queue.txt"

# Runtime variables
PROCESSED=0 # Flag to check if processed files are present
BURST_DIR="${1%/}"
TARGET_NAME="$2"
TARGET_DIR=$(dirname "${TARGET_NAME}")
SAVE_DNG="$3"
LOGFILE="${TARGET_NAME}.log"
MAIN_PICTURE="${BURST_DIR}/1"


# keep track of the last executed command
trap 'LAST_COMMAND=$CURRENT_COMMAND; CURRENT_COMMAND=$BASH_COMMAND' DEBUG
# echo an error message before exiting
trap 'trap_die' EXIT

log() {
    MESSAGE=$(printf '[%s] %s: %s\n' "$(date)" "$FUNCTION" "$1")
    
    printf '%s\n' "$MESSAGE" >> "$LOGFILE"
}

trap_die() {
    EXIT_CODE="$?"

    if [ -f "${POSTPROCESS_QUEUE_FILE}" ]; then
        # Remove all instances of ${QUEUE_NAME} from ${POSTPROCESS_QUEUE_FILE} file
        sed -i "/${ESCAPED_QUEUE_NAME}/d" "${POSTPROCESS_QUEUE_FILE}"
    fi

    if [ "${EXIT_CODE}" -eq 0 ]; then
        log "Completed successfully, cleaning up"
        rm -f "${LOGFILE:?}"
    else
        log "ERROR: \"${CURRENT_COMMAND}\" command failed with exit code ${EXIT_CODE}."
    fi
}

check_command() {
    local COMMAND_CHECK
    local COMMAND_NAME
    
    # Grab the actual command from the string
    COMMAND_NAME=$(echo "$1" | awk '{print $1}')

    # Check if the command exists if not check if container runtime exists
    if command -v "${COMMAND_NAME}" &> /dev/null; then
        COMMAND_CHECK=0
    elif command -v "${CONTAINER_RUNTIME}" &> /dev/null; then
        COMMAND_CHECK=0
    else
        COMMAND_CHECK=1
    fi

    if [ "${COMMAND_CHECK}" -eq 1 ]; then
        log "ERROR: ${COMMAND_NAME} and ${CONTAINER_RUNTIME} command not found"
    fi

    printf "%d" "${COMMAND_CHECK}"
}

run() {
    local ret
    local COMMAND_NAME
    local COMMAND_ARG

    COMMAND_ARG="$1"

    # Grab the actual command from the string
    COMMAND_NAME=$(echo "$COMMAND_ARG" | awk '{print $1}')

    # Check if the command is a function
    if declare -f "$COMMAND_NAME" > /dev/null
    then
        log "Running: $*"
        ret=$(eval "$COMMAND_ARG" 2>&1)
    else
        if [ "$(check_command "$COMMAND_NAME")" ]; then
            MOUNTS="-v \"${BURST_DIR}:/mnt\" -v \"${TARGET_DIR}:/destination\""


            # if force container is not enabled and if the command exists run it
            if [ "$FORCE_CONTAINER" -eq 0 ] && [ -x "$(command -v "$COMMAND_NAME")" ]; then
                log "Running: $COMMAND_ARG"
                ret=$(eval "$COMMAND_ARG" 2>&1)
            elif [ -x "$(command -v "$CONTAINER_RUNTIME")" ]; then
                # Do not replace if BURST_DIR or TARGET_DIR starts with a dot
                if [[ "$BURST_DIR" == .* ]] || [[ "$TARGET_DIR" == .* ]]; then
                    log "ERROR: BURST_DIR or TARGET_DIR need to be a full path"
                    log " BURST_DIR: $BURST_DIR"
                    log " TARGET_DIR: $TARGET_DIR"
                    exit 1
                fi
                COMMAND_ARG="${COMMAND_ARG//$BURST_DIR/\/mnt}"
                COMMAND_ARG="${COMMAND_ARG//$TARGET_DIR/\/destination}"
                RUN_COMMAND="${CONTAINER_RUNTIME} run --rm -it ${MOUNTS} --user 0 --rm \"${DOCKER_IMAGE}\" $COMMAND_ARG"
                log "Running: $RUN_COMMAND"
                ret=$(eval "$RUN_COMMAND" 2>&1)
            fi
        else
            ret="Command $COMMAND_NAME not found"
        fi

    fi

    log "Returned: $ret"
}

exiftool_function() {
    # Copy exif data from one image to another
    run "exiftool -fast -software=\"Megapixels\" \
        -x ImageWidth -x ImageHeight -x ImageSize -x Orientation -x ColorSpace -x Compression \
        -overwrite_original -tagsFromfile \"$1\" \"$2\""
}

finalize_image() {
    log "Finalize image"

    local FALLBACK
    FALLBACK=0
    
    local IMAGE_PATH
    IMAGE_PATH="${1%.*}"

    if [ "$EXTERNAL_EXTENSION" = "jxl" ]; then
        if check_command "cjxl"; then
            # if internal extension is not png then convert to png first due to cjxl limits
            if [ "$INTERNAL_EXTENSION" != "png" ]; then
                convert "${1}" "${IMAGE_PATH}.png"
            fi

            run "cjxl -e 4 -q ${IMAGE_QUALITY} \"${IMAGE_PATH}.png\" \"${2}.${EXTERNAL_EXTENSION}\""
        else
            FALLBACK=1
        fi
    elif [ "$EXTERNAL_EXTENSION" = "avif" ]; then
        if check_command "cavif"; then
            # if internal extension is not png then convert to png first due to cavif limits
            if [ "$INTERNAL_EXTENSION" != "png" ]; then
                convert "${1}" "${IMAGE_PATH}.png"
            fi

            run "cavif --overwrite --speed 6 -Q ${IMAGE_QUALITY} \"${IMAGE_PATH}.png\" -o \"${2}.${EXTERNAL_EXTENSION}\""
        else
            FALLBACK=1
        fi
    elif [ "$EXTERNAL_EXTENSION" = "$INTERNAL_EXTENSION" ]; then
        run "mv -f \"${1}\" \"${2}.${INTERNAL_EXTENSION}\""
    else
        run "convert \"${1}\" -quality ${IMAGE_QUALITY}% \"${2}.${EXTERNAL_EXTENSION}\""
    fi

    if [ "$FALLBACK" -eq 1 ]; then
        log "Failed to use ${EXTERNAL_EXTENSION} using ${INTERNAL_EXTENSION} instead"
        EXTERNAL_EXTENSION="${INTERNAL_EXTENSION}"
        run "mv -f \"${1}\" \"${2}.${INTERNAL_EXTENSION}\""
    fi

    # Put exif data into the final image
    # Do not run on jxl or png as it seems to not actually put the exif data in them
    if [ "${EXTERNAL_EXTENSION}" != "jxl" ] && [ "${EXTERNAL_EXTENSION}" != "png" ]; then
        run "exiftool_function \"${MAIN_PICTURE}.dng\" \"${2}.${EXTERNAL_EXTENSION}\""
    fi
}

post_process() {
    FUNCTION="post_process"
    log "Starting post-processing"

    local ALL_IN_ONE_FLAGS

    FUNCTION="post_process: all_in_one"
    log "Starting all_in_one"
    ALL_IN_ONE_FLAGS="--internal_image_extension ${INTERNAL_EXTENSION} --histogram_method histogram_clahe --scale_down 540"

    if [ "${PARALLEL_RAW}" -gt 0 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --parallel_raw ${PARALLEL_RAW}"
    fi

    if [ "${AUTO_WHITE_BALANCE}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --auto_white_balance"
    fi

    if [ "${SHRINK_IMAGES}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --shrink_images"
    fi

    if [ "${AUTO_STACK}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --auto_stack --stack_method ECC --stack_amount 2"
        PROCESSED=1
    fi

    if [ "${DEHAZE}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --dehaze_method darktables"
        PROCESSED=1
    fi

    if [ "${DENOISE_ALL}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --denoise_all --denoise_all_method fast --denoise_all_amount 2"
        PROCESSED=1
    fi

    if [ "${DENOISE}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --denoise --denoise_method fast --denoise_amount 2"
        PROCESSED=1
    fi

    if [ "${COLOR}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --color_method image_adaptive_3dlut"
        PROCESSED=1
    fi

    if [ "${SUPER_RESOLUTION}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --super_resolution --super_resolution_method ESPCN --super_resolution_scale 2"
        PROCESSED=1
    fi

    if [ "${SHARPEN}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --sharpen unsharp_mask --sharpen_amount ${SHARPEN_AMOUNT}"
    fi

    if [ "${HALF_SIZE}" -eq 1 ]; then
        ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --half_size"
    fi

    if [ -f "${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py" ]; then
        COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py"
    else
        COMMAND="all_in_one"
    fi

    run "${COMMAND} \"${BURST_DIR}\" \"${ALL_IN_ONE_FLAGS}\" 2>&1"

    run "finalize_image \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\" \"${TARGET_NAME}\""

    if [ "$PROCESSED" -eq 1 ]; then
        run "finalize_image \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\" \"${TARGET_NAME}_processed\""
    fi
}

FUNCTION="main" # Variable to hold the stage of the script for log output
TIMESTAMP=$(date +%s%3N)

QUEUE_NAME="${TARGET_NAME}_${TIMESTAMP}"
ESCAPED_QUEUE_NAME=$(printf '%s\n' "${QUEUE_NAME}" | sed -e 's/[]\/$*.^[]/\\&/g');

log "$0 $*"

# Copy the first frame of the burst as the raw photo
if [ "$SAVE_DNG" -eq 1 ]; then
    log "Saving DNG"
    run "cp \"${MAIN_PICTURE}.dng\" \"${TARGET_NAME}.dng\""
fi

# Check if $QUEUE_NAME exists in POSTPROCESS_QUEUE_FILE, if so exit if not append $QUEUE_NAME to POSTPROCESS_QUEUE_FILE
# This is used by the megapixels script to determine if it should be ran or if another instance is already running
if [ -f "${POSTPROCESS_QUEUE_FILE}" ]; then
    if grep -q "${QUEUE_NAME}" "${POSTPROCESS_QUEUE_FILE}"; then
        log "Skipping ${QUEUE_NAME}, already queued"
        exit 0
    fi
fi

printf "%s\n" "${QUEUE_NAME}" >> "${POSTPROCESS_QUEUE_FILE}"
FIRST_LINE=$(head -n 1 ${POSTPROCESS_QUEUE_FILE})

# Loop until the first line in the queue is the same as the current instance
while [ "${FIRST_LINE}" != "${QUEUE_NAME}" ]; do
    sleep 5
    FIRST_LINE=$(head -n 1 ${POSTPROCESS_QUEUE_FILE})
done

run "post_process"
