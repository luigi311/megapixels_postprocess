#!/bin/sh

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
    printf '[%s] %s: %s\n' "$(date)" "$FUNCTION" "$1" >>"${LOGFILE}"
}

trap_die() {
    EXIT_CODE="$?"
    if [ "${EXIT_CODE}" -eq 0 ]; then
        rm -f "${LOGFILE:?}"
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
INTERNAL_EXTENSION="png"
EXTERNAL_EXTENSION="png"
LOGFILE="${TARGET_NAME}.log"
MAIN_PICTURE="${BURST_DIR}/1"
PROCESSED=0
AUTO_STACK=1
SUPER_RESOLUTION=1
LOW_POWER_IMAGE_PROCESSING="/etc/megapixels/Low-Power-Image-Processing"
FUNCTION="main"

# Copy the first frame of the burst as the raw photo
cp "${MAIN_PICTURE}.dng" "${TARGET_NAME}.dng"

# Create a .jpg if raw processing tools are installed
DCRAW=""
TIFF_EXT="dng.tiff"
if command -v "dcraw_emu" >/dev/null; then
    DCRAW=dcraw_emu
    # -fbdd 1	Raw denoising with FBDD
    set -- -fbdd 1
elif [ -x "/usr/lib/libraw/dcraw_emu" ]; then
    DCRAW=/usr/lib/libraw/dcraw_emu
    # -fbdd 1	Raw denoising with FBDD
    set -- -fbdd 1
elif command -v "dcraw" >/dev/null; then
    DCRAW=dcraw
    TIFF_EXT="tiff"
    set --
fi

CONVERT=""
if command -v "convert" >/dev/null; then
    CONVERT="convert"
    # -fbdd 1	Raw denoising with FBDD
    set -- -fbdd 1
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
    log "$DCRAW +M -H 4 -o 1 -q 3 -T \"$*\" \"${MAIN_PICTURE}.dng\""
    $DCRAW +M -H 4 -o 1 -q 3 -T "$@" "${MAIN_PICTURE}.dng"

    # If imagemagick is available, convert the tiff to jpeg and apply slight sharpening
    if [ -n "$CONVERT" ]; then
        if [ "$CONVERT" = "convert" ]; then
            log "convert \"${MAIN_PICTURE}.${TIFF_EXT}\" -sharpen 0x1.0 -sigmoidal-contrast 6,50% \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
            convert "${MAIN_PICTURE}.${TIFF_EXT}" -sharpen 0x1.0 -sigmoidal-contrast 6,50% "${BURST_DIR}/main.${INTERNAL_EXTENSION}"
        else
            # sadly sigmoidal contrast is not available in imagemagick
            log "Sigmoidal contrast not avaliable convert \"${MAIN_PICTURE}.${TIFF_EXT}\" -sharpen 0x1.0 \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
            gm convert "${MAIN_PICTURE}.${TIFF_EXT}" -sharpen 0x1.0 "${BURST_DIR}/main.${INTERNAL_EXTENSION}"
        fi

        log "exiftool_function \"${MAIN_PICTURE}.${TIFF_EXT}\" \"${BURST_DIR}/main.${INTERNAL_EXTENSION}\""
        exiftool_function "${MAIN_PICTURE}.${TIFF_EXT}" "${BURST_DIR}/main.${INTERNAL_EXTENSION}"

        log "finalize_image ${BURST_DIR}/main.${INTERNAL_EXTENSION} ${TARGET_NAME}"
        finalize_image "${BURST_DIR}/main.${INTERNAL_EXTENSION}" "${TARGET_NAME}"

        if [ "$AUTO_STACK" -eq 1 ]; then
            # Proceed if python scripts exist or if podman is installed
            if [ -f "${LOW_POWER_IMAGE_PROCESSING}/stacking/auto_stack/auto_stack.py" ] || command -v "podman" >/dev/null; then
                FUNCTION="auto_stack"
                log "Starting auto stack process"
                for FILE in "${BURST_DIR}"/*.dng; do
                    log "$DCRAW +M -H 4 -o 1 -q 3 -T ${FILE}"
                    $DCRAW +M -H 4 -o 1 -q 3 -T "${FILE}"
                done

                # Remove original main conversion so it is not included in the stacking
                log "Removing: ${BURST_DIR}/main.${INTERNAL_EXTENSION} to prevent double stacking"
                rm -f "${BURST_DIR}/main.${INTERNAL_EXTENSION}"

                if [ -f "${LOW_POWER_IMAGE_PROCESSING}/stacking/auto_stack/auto_stack.py" ]; then
                    COMMAND="python ${LOW_POWER_IMAGE_PROCESSING}/stacking/auto_stack/auto_stack.py"
                    PREFIX="${BURST_DIR}"
                else
                    COMMAND="podman run -v \"${BURST_DIR}:/mnt\" --rm docker.io/luigi311/low-power-image-processing:latest auto_stack"
                    PREFIX="/mnt"
                fi

                INPUT_FOLDER="${PREFIX}"
                OUTPUT_IMAGE="${PREFIX}/main_processed.${INTERNAL_EXTENSION}"

                log "${COMMAND} \"${INPUT_FOLDER}\" \"${OUTPUT_IMAGE}\" --method ECC --filter_contrast"
                $COMMAND "${INPUT_FOLDER}" "${OUTPUT_IMAGE}" --method ECC --filter_contrast

                log "exiftool_function \"${MAIN_PICTURE}.${TIFF_EXT}\" \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\""
                exiftool_function "${MAIN_PICTURE}.${TIFF_EXT}" "${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}"

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
                    PREFIX="${BURST_DIR}"
                else
                    COMMAND="podman run -v \"${BURST_DIR}:/mnt\" --rm docker.io/luigi311/low-power-image-processing:latest opencv_super_resolution"
                    PREFIX="/mnt"
                fi

                INPUT_IMAGE="${PREFIX}/${INPUT_IMAGE}"
                OUTPUT_IMAGE="${PREFIX}/main_processed2.${INTERNAL_EXTENSION}"

                log "${COMMAND} \"${INPUT_IMAGE}\" \"${OUTPUT_IMAGE}\" --method ESPCN --scale 2 --model_path \"${HOME}/.models\""
                $COMMAND "${INPUT_IMAGE}" "${OUTPUT_IMAGE}" --method ESPCN --scale 2 --model_path "${HOME}/.models"

                mv "${BURST_DIR}/main_processed2.${INTERNAL_EXTENSION}" "${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}"

                PROCESSED=1
            fi
        fi

        FUNCTION="main"
        if [ "$PROCESSED" -eq 1 ]; then
            log "finalize_image \"${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}\" \"${TARGET_NAME}_processed\""
            finalize_image "${BURST_DIR}/main_processed.${INTERNAL_EXTENSION}" "${TARGET_NAME}_processed"
        fi

        log "Complete"
    else
        cp "${MAIN_PICTURE}.${TIFF_EXT}" "${TARGET_NAME}.tiff"

        echo "${TARGET_NAME}.tiff"
    fi
fi

# Clean up the temp dir containing the burst
#rm -rf "$BURST_DIR"

# Clean up the .dng if the user didn't want it
if [ "$SAVE_DNG" -eq "0" ]; then
    rm "$TARGET_NAME.dng"
fi
