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
    if [ "${EXIT_CODE}" -eq 0 ]; then
        log "Exiting with code ${EXIT_CODE}"
        #rm -f "${LOGFILE:?}"
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
            cjxl "$1" "${2}.${OUTPUT_EXTENSION}"
        else
            FALLBACK=1
        fi
    elif [ "$EXTERNAL_EXTENSION" = "png" ]; then
        OUTPUT_EXTENSION="png"
        cp "$1" "${2}.png"
    else
        OUTPUT_EXTENSION="$EXTERNAL_EXTENSION"
        convert "$1" "${2}.${OUTPUT_EXTENSION}"
    fi

    if [ "$FALLBACK" -eq 1 ]; then
        OUTPUT_EXTENSION="png"
        cp "$1" "${2}.png"
    fi
}

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 [burst-dir] [target-name] [save-dng]"
    exit 2
fi
BURST_DIR="${1%/}"
TARGET_NAME="$2"
SAVE_DNG="$3"
INTERNAL_EXTENSION="png" # Image extension to use for internal outputs, recommended to use a lossless format
EXTERNAL_EXTENSION="png" # Final image extension to output the final image
LOGFILE="${TARGET_NAME}.log"
MAIN_PICTURE="${BURST_DIR}/1"
PROCESSED=0 # Flag to check if processed files are present
DENOISE=0 # Enable denoise, set to 0 to disable, disabled by default due to poor performance on some devices
AUTO_STACK=1 # Enable auto stacking, set to 0 to disable, set to 1 to enable
SUPER_RESOLUTION=0 # Enable Super Resolution, set to 0 to disable, set to 1 to enable
LOW_POWER_IMAGE_PROCESSING="/etc/megapixels/Low-Power-Image-Processing"
DOCKER_IMAGE="docker.io/luigi311/low-power-image-processing:latest"
FUNCTION="main" # Variable to hold the stage of the script for log output

log "Starting post-processing"
log "/etc/megapixels/postprocess.sh ${1} ${2} ${3}"

# Copy the first frame of the burst as the raw photo
cp "${MAIN_PICTURE}.dng" "${TARGET_NAME}.dng"

# Create a .jpg if raw processing tools are installed
DCRAW=""
TIFF_EXT="dng.tiff"
if command -v "dcraw_emu" >/dev/null; then
    DCRAW=dcraw_emu
    # -fbdd 1	Raw denoising with FBDD
    denoise="-fbdd 1"
elif [ -x "/usr/lib/libraw/dcraw_emu" ]; then
    DCRAW=/usr/lib/libraw/dcraw_emu
    # -fbdd 1	Raw denoising with FBDD
    denoise="-fbdd 1"
elif command -v "dcraw" >/dev/null; then
    DCRAW=dcraw
    TIFF_EXT="tiff"
fi

CONVERT=""
if command -v "convert" >/dev/null; then
    CONVERT="convert"
    # -fbdd 1	Raw denoising with FBDD
    denoise="-fbdd 1"
elif command -v "gm" >/dev/null; then
    CONVERT="gm"
fi

if [ -n "$DCRAW" ]; then
    # $DCRAW FLAGS
    # +M		use embedded color matrix
    # -H 4		Recover highlights by rebuilding them
    # -o 1		Output in sRGB colorspace
    # -q 3		Debayer with AHD algorithm
    # -T		Output TIFF
    
    run "$DCRAW +M -H 4 -o 1 -q 3 -T ${denoise} \"${MAIN_PICTURE}.dng\""

    # If imagemagick is available, convert the tiff to jpeg and apply slight sharpening
    if [ -n "$CONVERT" ]; then
        if [ "$CONVERT" = "convert" ]; then
            run "convert \"${MAIN_PICTURE}.${TIFF_EXT}\" -sharpen 0x1.0 -sigmoidal-contrast 6,50% \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
        else
            # sadly sigmoidal contrast is not available in imagemagick
            run "gm convert \"${MAIN_PICTURE}.${TIFF_EXT}\" -sharpen 0x1.0 \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
        fi

        run "exiftool_function \"${MAIN_PICTURE}.${TIFF_EXT}\" \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
        run "finalize_image ${BURST_DIR}/main.${INTERNAL_EXTENSION} ${TARGET_NAME}"

        if [ "$DENOISE" -eq 1 ]; then
            if [ -f "${LOW_POWER_IMAGE_PROCESSING}/denoise/denoise/denoise.py" ] || command -v "podman" >/dev/null; then
                FUNCTION="denoise"
                log "Starting denoise process"
                if [ "$AUTO_STACK" -eq 1 ]; then
                    for FILE in "${BURST_DIR}"/*.dng; do
                        run "$DCRAW +M -H 4 -o 1 -q 3 -T \"${FILE}\""
                    done
                else
                    run "$DCRAW +M -H 4 -o 1 -q 3 -T \"${MAIN_PICTURE}.dng\""
                fi
                
                # Remove original main conversion so it is not included in the stacking
                log "Removing: ${BURST_DIR}/main.${INTERNAL_EXTENSION} to prevent double stacking"
                run "rm -f \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""

                if [ -f "${LOW_POWER_IMAGE_PROCESSING}/denoise/ffdnet/ffdnet.py" ]; then
                    COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/denoise/ffdnet/ffdnet.py"
                    PREFIX="${BURST_DIR}"
                    MODEL_PATH="--model_path \"${HOME}/.models\""
                else
                    COMMAND="podman run -v ${BURST_DIR}:/mnt --user 0 --rm ${DOCKER_IMAGE} ffdnet"
                    PREFIX="/mnt"
                    MODEL_PATH=""
                fi

                INPUT_FOLDER="${PREFIX}"

                run "${COMMAND} \"${INPUT_FOLDER}\" --noise 10 --model \"ffdnet_color\" ${MODEL_PATH} 2>&1"
            fi
        fi

        if [ "$AUTO_STACK" -eq 1 ]; then
            # Proceed if python scripts exist or if podman is installed
            if [ -f "${LOW_POWER_IMAGE_PROCESSING}/stacking/auto_stack/auto_stack.py" ] || command -v "podman" >/dev/null; then
                FUNCTION="auto_stack"
                log "Starting auto stack process"
                
                # Check if denoise was not ran as that will dcraw the images first
                if [ ! "$DENOISE" -eq 1 ]; then
                    for FILE in "${BURST_DIR}"/*.dng; do
                        run "$DCRAW +M -H 4 -o 1 -q 3 -T \"${FILE}\""
                    done
                fi

                # Remove original main conversion so it is not included in the stacking
                log "Removing: ${BURST_DIR}/main.${INTERNAL_EXTENSION} to prevent double stacking"
                run "rm -f \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""

                if [ -f "${LOW_POWER_IMAGE_PROCESSING}/stacking/auto_stack/auto_stack.py" ]; then
                    COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/stacking/auto_stack/auto_stack.py"
                    PREFIX="${BURST_DIR}"
                else
                    COMMAND="podman run -v ${BURST_DIR}:/mnt --user 0 --rm ${DOCKER_IMAGE} auto_stack"
                    PREFIX="/mnt"
                fi

                INPUT_FOLDER="${PREFIX}"
                OUTPUT_IMAGE="${PREFIX}/main_processed.${INTERNAL_EXTENSION}"

                run "${COMMAND} \"${INPUT_FOLDER}\" \"${OUTPUT_IMAGE}\" --method ECC --filter_contrast 2>&1"

                run "exiftool_function \"${MAIN_PICTURE}.${TIFF_EXT}\" \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\""

                PROCESSED=1
            fi
        fi

        if [ "$SUPER_RESOLUTION" -eq 1 ]; then
            if [ -f "${LOW_POWER_IMAGE_PROCESSING}/super_resolution/opencv_super_resolution/opencv_super_resolution.py" ] || command -v "podman" >/dev/null; then
                FUNCTION="super_resolution"
                log "Starting super resolution process"
                if [ "$PROCESSED" -eq 1 ]; then
                    INPUT_IMAGE="main_processed.${INTERNAL_EXTENSION}"
                else
                    INPUT_IMAGE="main.${INTERNAL_EXTENSION}"
                fi

                if [ -f "${LOW_POWER_IMAGE_PROCESSING}/super_resolution/opencv_super_resolution/opencv_super_resolution.py" ]; then
                    COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/super_resolution/opencv_super_resolution/opencv_super_resolution.py"
                    MODEL_PATH="--model_path \"${HOME}/.models\""
                    PREFIX="${BURST_DIR}"
                else
                    COMMAND="podman run -v ${BURST_DIR}:/mnt --user 0 --rm ${DOCKER_IMAGE} opencv_super_resolution"
                    MODEL_PATH=""
                    PREFIX="/mnt"
                fi

                INPUT_IMAGE="${PREFIX}/${INPUT_IMAGE}"
                OUTPUT_IMAGE="${PREFIX}/main_processed2.${INTERNAL_EXTENSION}"

                run "${COMMAND} \"${INPUT_IMAGE}\" \"${OUTPUT_IMAGE}\" --method ESPCN --scale 2 ${MODEL_PATH} 2>&1"

                run "mv \"${BURST_DIR}/main_processed2.${INTERNAL_EXTENSION}\" \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\""

                PROCESSED=1
            fi
        fi

        FUNCTION="main"
        if [ "$PROCESSED" -eq 1 ]; then
            run "finalize_image \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\" \"${TARGET_NAME}_processed\""
        fi

        log "Complete"
    else
        run "cp \"${MAIN_PICTURE}.${TIFF_EXT}\" \"${TARGET_NAME}.tiff\""
    fi
fi

# Clean up the temp dir containing the burst
#rm -rf "$BURST_DIR"

# Clean up the .dng if the user didn't want it
if [ "$SAVE_DNG" -eq "0" ]; then
    run "rm \"$TARGET_NAME.dng\""
fi
