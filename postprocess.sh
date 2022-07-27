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

# keep track of the last executed command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
# echo an error message before exiting
trap 'trap_die' EXIT

log() {
    printf '[%s] %s: %s\n' "$(date)" "$FUNCTION" "$1" >> "${LOGFILE}"
}

run() {
    # Run and time command down to the millisecond
    log "Running: $*"
    local start=$(date +%s%3N)
    local ret=$(eval "$1" 2>&1)
    local end=$(date +%s%3N)
    local duration=$((end - start))
    log "Command took $duration milliseconds"
    log "Returned: $ret"
}

trap_die() {
    EXIT_CODE="$?"

    # Remove all instances of ${QUEUE_NAME} from ${POSTPROCESS_QUEUE_FILE} file
    sed -i "/${ESCAPED_QUEUE_NAME}/d" "${POSTPROCESS_QUEUE_FILE}"
    sed -i "/${ESCAPED_QUEUE_NAME}/d" "${SINGLE_QUEUE_FILE}"

    if [ "${EXIT_CODE}" -eq 0 ]; then
        log "Completed successfully, cleaning up"
        rm -f "${LOGFILE:?}"

        # Clean up the temp dir containing the burst
        rm -rf "${BURST_DIR:?}"
    else
        MESSAGE="ERROR \"${current_command}\" command filed with exit code ${EXIT_CODE}."
        log "${MESSAGE}"
    fi
}

exiftool_function() {
    # If exiftool is installed copy the exif data over from the tiff to the jpeg
    # since imagemagick is stupid
    if command -v exiftool >/dev/null; then
        exiftool -tagsFromfile "$1" \
        -software="Megapixels" \
        -fast \
        -overwrite_original "$2"
    fi
}

finalize_image() {
    FALLBACK=0

    if [ "$EXTERNAL_EXTENSION" = "jxl" ]; then
        if command -v "cjxl" >/dev/null; then
            OUTPUT_EXTENSION="jxl"
            cjxl -q 95 "${1}" "${2}.${OUTPUT_EXTENSION}"
        else
            FALLBACK=1
        fi
    elif [ "$EXTERNAL_EXTENSION" = "avif" ]; then
        if command -v "cavif" >/dev/null; then
            IMAGE="${1%.*}"

            # if internal extension is no png then convert to png first due to cavif limits
            if [ "$INTERNAL_EXTENSION" != "png" ]; then
                convert "${1}" "${IMAGE}.png"
                INPUT_EXTENSION="png"
            fi

            OUTPUT_EXTENSION="avif"
            cavif -f -s 6 -Q 80 "${IMAGE}.png" -o "${2}.avif"
        else
            FALLBACK=1
        fi
    elif [ "$EXTERNAL_EXTENSION" = "png" ] && [ "$INTERNAL_EXTENSION" = "png" ]; then
        OUTPUT_EXTENSION="png"
        cp "${1}" "${2}.png"
    else
        OUTPUT_EXTENSION="$EXTERNAL_EXTENSION"
        convert "${1}" "${2}.${OUTPUT_EXTENSION}"
    fi

    if [ "$FALLBACK" -eq 1 ]; then
        OUTPUT_EXTENSION="png"
        cp "${1}" "${2}.png"
    fi
}

single_image() {
    FUNCTION="single_image"
    log "Processing single image"

    # If using all_in_one
    if [ "${ALL_IN_ONE}" -eq 1 ]; then
        if [ -f "${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py" ] || command -v "podman" >/dev/null; then
            FUNCTION="single_image: all_in_one"
            log "Starting all_in_one"
            ALL_IN_ONE_FLAGS="--single_image --interal_image_extension ${INTERNAL_EXTENSION} --contrast_method histogram_clahe"

            if [ -f "${LOW_POWER_IMAGE_PROCESSING}/all_in_one/all_in_one.py" ]; then
                COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/all_in_one/all_in_one.py"
                INPUT_FOLDER="${BURST_DIR}"
            else
                COMMAND="podman run -v ${BURST_DIR}:/mnt --user 0 --rm ${DOCKER_IMAGE} all_in_one"
                INPUT_FOLDER="/mnt"
            fi

            run "${COMMAND} \"${INPUT_FOLDER}\" \"${ALL_IN_ONE_FLAGS}\" 2>&1"

            run "finalize_image ${BURST_DIR}/main.${INTERNAL_EXTENSION} ${TARGET_NAME}"
        fi
    else
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

                run "exiftool_function \"${MAIN_PICTURE}.${TIFF_EXT}\" \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
                run "finalize_image ${BURST_DIR}/main.${INTERNAL_EXTENSION} ${TARGET_NAME}"

                log "Complete"
            else
                run "finalize_image \"${MAIN_PICTURE}.${TIFF_EXT}\" ${TARGET_NAME}"
            fi
        fi
    fi
}

post_process() {
    FUNCTION="post_process"
    log "Starting post-processing"
    # If using all_in_one
    if [ "${ALL_IN_ONE}" -eq 1 ]; then
        if [ -f "${LOW_POWER_IMAGE_PROCESSING}/all_in_one.py" ] || command -v "podman" >/dev/null; then
            FUNCTION="post_process: all_in_one"
            log "Starting all_in_one"
            ALL_IN_ONE_FLAGS="--interal_image_extension ${INTERNAL_EXTENSION} --contrast_method histogram_clahe"

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

            if [ -f "${LOW_POWER_IMAGE_PROCESSING}/all_in_one/all_in_one.py" ]; then
                COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/all_in_one/all_in_one.py"
                INPUT_FOLDER="${BURST_DIR}"
            else
                COMMAND="podman run -v ${BURST_DIR}:/mnt --user 0 --rm ${DOCKER_IMAGE} all_in_one"
                INPUT_FOLDER="/mnt"
            fi

            run "${COMMAND} \"${INPUT_FOLDER}\" \"${ALL_IN_ONE_FLAGS}\" 2>&1"

            run "finalize_image ${BURST_DIR}/main.${INTERNAL_EXTENSION} ${TARGET_NAME}"
            if [ "$PROCESSED" -eq 1 ]; then
                run "finalize_image \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\" \"${TARGET_NAME}_processed\""
            fi
        fi
    fi
}

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 [burst-dir] [target-name] [save-dng]"
    exit 2
fi

FUNCTION="main" # Variable to hold the stage of the script for log output
TIMESTAMP=$(date +%s%3N)
BURST_DIR="${1%/}"
TARGET_NAME="$2"
SAVE_DNG="$3"
LOGFILE="${TARGET_NAME}.log"

QUEUE_NAME="${TARGET_NAME}_${TIMESTAMP}"
ESCAPED_QUEUE_NAME=$(printf '%s\n' "${QUEUE_NAME}" | sed -e 's/[]\/$*.^[]/\\&/g');

# Setup Variables
INTERNAL_EXTENSION="png" # Image extension to use for internal outputs, recommended to use a lossless format
EXTERNAL_EXTENSION="png" # Final image extension to output the final image
MAIN_PICTURE="${BURST_DIR}/1"
SHRINK_IMAGES=0 # Shrink images by half to speed up prcoessing and then superresolution back up to the original size at the end
DEHAZE=0 # Flag to dehaze all images, set to 0 to disable, 1 to enable
DENOISE_ALL=0 # Flag to denoise all images, set to 0 to disable, 1 to enable
DENOISE=0 # Enable denoise, set to 0 to disable, disabled by default due to poor performance on some devices
AUTO_STACK=1 # Enable auto stacking, set to 0 to disable, set to 1 to enable
COLOR=0 # Enable color adjustments, set to 0 to disable, set to 1 to enable
SUPER_RESOLUTION=0 # Enable Super Resolution, set to 0 to disable, set to 1 to enable
ALL_IN_ONE=1 # Enable all in one script, set to 0 to disable, set to 1 to enable
LOW_POWER_IMAGE_PROCESSING="/etc/megapixels/Low-Power-Image-Processing"
DOCKER_IMAGE="docker.io/luigi311/low-power-image-processing:latest"
PROCESSED=0 # Flag to check if processed files are present
SINGLE_QUEUE_FILE="/tmp/megapixels_single_queue.txt"
POSTPROCESS_QUEUE_FILE="/tmp/megapixels_postprocess_queue.txt"

# Copy the first frame of the burst as the raw photo
if [ "$3" -eq 1 ]; then
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
echo "${QUEUE_NAME}" >> "${SINGLE_QUEUE_FILE}"

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
echo "${QUEUE_NAME}" >> "${POSTPROCESS_QUEUE_FILE}"

FIRST_LINE=$(head -n 1 ${POSTPROCESS_QUEUE_FILE})

# Loop until the first line in the queue is the same as the current instance
while [ "${FIRST_LINE}" != "${QUEUE_NAME}" ]; do
    sleep 5
    FIRST_LINE=$(head -n 1 ${POSTPROCESS_QUEUE_FILE})
done

run "post_process"
