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

# Processing variables
EXTERNAL_EXTENSION="png" # Final image extension to output the final image
IMAGE_QUALITY=90 # Quality of the final image when converting (0-100)
AUTO_STACK=1 # Enable auto stacking, set to 0 to disable, set to 1 to enable
SHRINK_IMAGES=0 # Shrink images by half to speed up prcoessing and then superresolution back up to the original size at the end
DEHAZE=0 # Flag to dehaze all images, set to 0 to disable, 1 to enable
DENOISE_ALL=0 # Flag to denoise all images, set to 0 to disable, 1 to enable
DENOISE=0 # Enable denoise, set to 0 to disable, disabled by default due to poor performance on some devices
COLOR=0 # Enable color adjustments, set to 0 to disable, set to 1 to enable
SUPER_RESOLUTION=0 # Enable Super Resolution, set to 0 to disable, set to 1 to enable
SHARPEN=1 # Enable to apply sharpening on the postprocessed image, set to 0 to disable, set to 1 to enable
SHARPEN_AMOUNT=1.0 # Amount of sharpening to apply to postprocessed image

# Setup variables
PARALLEL_RAW=2 # Amount of dng images to read in parallel
INTERNAL_EXTENSION="png" # Image extension to use for internal outputs, recommended to use a lossless format
FORCE_CONTAINER=0 # Force the use of container, set to 0 to disable, set to 1 to enable
LEGACY_STACK=0 # Force use the old legacy stack, set to 0 to disable, set to 1 to enable
CONTAINER_RUNTIME="podman" # Set the container runtime to use, podman or docker
LOW_POWER_IMAGE_PROCESSING="/etc/megapixels/Low-Power-Image-Processing" # Path to check for the low power image processing repo if not using docker containers
DOCKER_IMAGE="docker.io/luigi311/low-power-image-processing:latest"
SINGLE_QUEUE_FILE="/tmp/megapixels_single_queue.txt"
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
        sed -i "/${ESCAPED_QUEUE_NAME}/d" "${SINGLE_QUEUE_FILE}"
    fi

    if [ "${EXIT_CODE}" -eq 0 ]; then
        log "Completed successfully, cleaning up"
        rm -f "${LOGFILE:?}"

        # Clean up the temp dir containing the burst
        rm -rf "${BURST_DIR:?}"
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


            # If force container is set, run the command in a container
            # if command avaliable locally run it locally
            # if command not avaliable locally, run it in a container if avaliable
            if [ "$FORCE_CONTAINER" -eq 1 ]; then
                COMMAND_ARG="${COMMAND_ARG//$BURST_DIR/\/mnt}"
                COMMAND_ARG="${COMMAND_ARG//$TARGET_DIR/\/destination}"
                RUN_COMMAND="${CONTAINER_RUNTIME} run --rm ${MOUNTS} --user 0 --rm \"${DOCKER_IMAGE}\" $COMMAND_ARG"
                log "Running: $RUN_COMMAND"
                ret=$(eval "$RUN_COMMAND" 2>&1)
            elif [ -x "$(command -v "${COMMAND_NAME}")" ]; then
                log "Running: $COMMAND_ARG"
                ret=$(eval "$COMMAND_ARG" 2>&1)
            elif [ -x "$(command -v "$CONTAINER_RUNTIME")" ]; then
                COMMAND_ARG="${COMMAND_ARG//$BURST_DIR/\/mnt}"
                COMMAND_ARG="${COMMAND_ARG//$TARGET_DIR/\/destination}"
                RUN_COMMAND="${CONTAINER_RUNTIME} run --rm ${MOUNTS} --user 0 --rm \"${DOCKER_IMAGE}\" $COMMAND_ARG"
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
    # If exiftool is installed copy the exif data over from the tiff to the jpeg
    # since imagemagick is stupid
    run "exiftool -software=\"Megapixels\" -fast \
        -x ImageWidth -x ImageHeight -x ImageSize -x Orientation -x ColorSpace \
        -overwrite_original -tagsFromfile \"$1\" \"$2\""
}

finalize_image() {
    log "Finalize image"
    
    local FINALIZE_START
    FINALIZE_START=$(date +%s%3N)

    local FALLBACK
    FALLBACK=0
    
    local OUTPUT_EXTENSION
    OUTPUT_EXTENSION="${EXTERNAL_EXTENSION}"
    
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
        OUTPUT_EXTENSION="${INTERNAL_EXTENSION}"
    fi

    run "exiftool_function \"${MAIN_PICTURE}.dng\" \"${2}.${OUTPUT_EXTENSION}\""

    local FINALIZE_END
    FINALIZE_END=$(date +%s%3N)
    local FINALIZE_ELAPSED
    FINALIZE_ELAPSED=$((FINALIZE_END - FINALIZE_START))
    log "Elapsed time finalize: ${FINALIZE_ELAPSED} ms"
}

single_image() {
    FUNCTION="single_image"
    log "Processing single image"
    
    local SINGLE_START
    SINGLE_START=$(date +%s%3N)

    if [ "$LEGACY_STACK" -eq 0 ]; then
        FUNCTION="single_image: all_in_one"
        log "Starting all_in_one"
        ALL_IN_ONE_FLAGS="--single_image --parallel_raw ${PARALLEL_RAW} --interal_image_extension ${INTERNAL_EXTENSION} --histogram_method histogram_clahe --scale_down 540"

        if [ -f "${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py" ]; then
            COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py"
            INPUT_FOLDER="${BURST_DIR}"
        else
            COMMAND="all_in_one"
            INPUT_FOLDER="/mnt"
        fi

        if [ "$(check_command "${COMMAND}")" ]; then
            run "${COMMAND} \"${INPUT_FOLDER}\" \"${ALL_IN_ONE_FLAGS}\""
            run "finalize_image ${BURST_DIR}/main.${INTERNAL_EXTENSION} ${TARGET_NAME}"
        else
            log "Falling back to legacy stack"
            LEGACY_STACK=1
        fi
    fi
    
    if [ "$LEGACY_STACK" -eq 1 ]; then
        # Create using raw processing tools
        DCRAW=""
        TIFF_EXT="dng.tiff"
        
        if command -v "dcraw_emu" >/dev/null; then
            DCRAW=dcraw_emu
            # -fbdd 1   Raw denoising with FBDD
            denoise="-fbdd 1"
        elif [ -x "/usr/lib/libraw/dcraw_emu" ]; then
            DCRAW=/usr/lib/libraw/dcraw_emu
            # -fbdd 1   Raw denoising with FBDD
            denoise="-fbdd 1"
        elif command -v "dcraw" >/dev/null; then
            DCRAW=dcraw
            TIFF_EXT="tiff"
        fi

        CONVERT=""
        if command -v "convert" >/dev/null; then
            CONVERT="convert"
            # -fbdd 1   Raw denoising with FBDD
            denoise="-fbdd 1"
        elif command -v "gm" >/dev/null; then
            CONVERT="gm"
        fi

        if [ -n "${DCRAW}" ]; then
            # $DCRAW FLAGS
            # +M                use embedded color matrix
            # -H 4              Recover highlights by rebuilding them
            # -o 1              Output in sRGB colorspace
            # -q 3              Debayer with AHD algorithm
            # -T                Output TIFF

            run "${DCRAW} +M -H 4 -o 1 -q 3 -T ${denoise} \"${MAIN_PICTURE}.dng\""

            # If imagemagick is available, convert the tiff to jpeg and apply slight sharpening
            if [ -n "${CONVERT}" ]; then
                if [ "${CONVERT}" = "convert" ]; then
                    run "convert \"${MAIN_PICTURE}.${TIFF_EXT}\" -sharpen 0x1.0 -sigmoidal-contrast 6,50% \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
                else
                    # sadly sigmoidal contrast is not available in imagemagick
                    run "gm convert \"${MAIN_PICTURE}.${TIFF_EXT}\" -sharpen 0x1.0 \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
                fi

                run "finalize_image ${BURST_DIR}/main.${INTERNAL_EXTENSION} ${TARGET_NAME}"

                log "Complete"
            else
                run "finalize_image \"${MAIN_PICTURE}.${TIFF_EXT}\" ${TARGET_NAME}"
            fi
        else
            log "ERROR: No raw processing tools found"
        fi
    fi

    local SINGLE_END
    SINGLE_END=$(date +%s%3N)
    local SINGLE_ELAPSED
    SINGLE_ELAPSED=$((SINGLE_END - SINGLE_START))
    log "Elapsed time: ${SINGLE_ELAPSED} ms"
}

post_process() {
    FUNCTION="post_process"
    log "Starting post-processing"

    local POST_START
    POST_START=$(date +%s%3N)

    if [ "$LEGACY_STACK" -eq 0 ]; then
        FUNCTION="post_process: all_in_one"
        log "Starting all_in_one"
        ALL_IN_ONE_FLAGS="--parallel_raw ${PARALLEL_RAW} --interal_image_extension ${INTERNAL_EXTENSION} --histogram_method histogram_clahe --scale_down 540"

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
            ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --super_resolution_method ESPCN --super_resolution_scale 2"
            PROCESSED=1
        fi

        if [ "${SHARPEN}" -eq 1 ]; then
            ALL_IN_ONE_FLAGS="${ALL_IN_ONE_FLAGS} --sharpen unsharp_mask --sharpen_amount ${SHARPEN_AMOUNT}"
        fi

        if [ -f "${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py" ]; then
            COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py"
            INPUT_FOLDER="${BURST_DIR}"
        else
            COMMAND="all_in_one"
            INPUT_FOLDER="/mnt"
        fi

        if [ "$PROCESSED" -eq 1 ]; then
            run "${COMMAND} \"${INPUT_FOLDER}\" \"${ALL_IN_ONE_FLAGS}\" 2>&1"
            run "finalize_image \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\" \"${TARGET_NAME}_processed\""
        fi
    fi

    local POST_END
    POST_END=$(date +%s%3N)
    local POST_ELAPSED
    POST_ELAPSED=$((POST_END - POST_START))
    log "Elapsed time: ${POST_ELAPSED} ms"
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

# Check if $QUEUE_NAME exists in SINGLE_QUEUE_FILE, if so exit if not append $QUEUE_NAME to SINGLE_QUEUE_FILE
# This is used by the megapixels script to determine if it should be ran or if another instance is already running
if [ -f "${SINGLE_QUEUE_FILE}" ]; then
    if grep -q "${QUEUE_NAME}" "${SINGLE_QUEUE_FILE}"; then
        log "Skipping ${QUEUE_NAME}, already queued"
        exit 0
    fi
fi

printf "%s\n" "${QUEUE_NAME}" >> "${SINGLE_QUEUE_FILE}"
FIRST_LINE=$(head -n 1 ${SINGLE_QUEUE_FILE})

# Loop until the first line in the queue is the same as the current instance
while [ "${FIRST_LINE}" != "${QUEUE_NAME}" ]; do
    sleep 5
    FIRST_LINE=$(head -n 1 ${SINGLE_QUEUE_FILE})
done

run "single_image"

# Remove from single queue file if it exists
sed -i "/${ESCAPED_QUEUE_NAME}/d" "${SINGLE_QUEUE_FILE}"

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
