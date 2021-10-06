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

exiftool_function () {
    # If exiftool is installed copy the exif data over from the tiff to the jpeg
    # since imagemagick is stupid
    if command -v exiftool > /dev/null
    then
        exiftool -tagsFromfile "$1" \
            -software="Megapixels" \
            -fast \
            -overwrite_original "$2"
    fi
}

finalize_image () {
    FALLBACK=0

    if [ "$EXTERNAL_EXTENSION" = "jxl" ]; then
        if command -v "cjxl" > /dev/null; then
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

BURST_DIR="$1"
TARGET_NAME="$2"
SAVE_DNG="$3"
INTERNAL_EXTENSION="png"
EXTERNAL_EXTENSION="png"

MAIN_PICTURE="${BURST_DIR}/1"

# Copy the first frame of the burst as the raw photo
cp "${MAIN_PICTURE}.dng" "${TARGET_NAME}.dng"

# Create a .jpg if raw processing tools are installed
DCRAW=""
TIFF_EXT="dng.tiff"
if command -v "dcraw_emu" > /dev/null
then
	DCRAW=dcraw_emu
	# -fbdd 1	Raw denoising with FBDD
	set -- -fbdd 1
elif [ -x "/usr/lib/libraw/dcraw_emu" ]; then
	DCRAW=/usr/lib/libraw/dcraw_emu
	# -fbdd 1	Raw denoising with FBDD
	set -- -fbdd 1
elif command -v "dcraw" > /dev/null
then
	DCRAW=dcraw
	TIFF_EXT="tiff"
	set --
fi

CONVERT=""
if command -v "convert" > /dev/null
then
	CONVERT="convert"
	# -fbdd 1	Raw denoising with FBDD
	set -- -fbdd 1
elif command -v "gm" > /dev/null
then
	CONVERT="gm"
fi

if [ -n "$DCRAW" ]; then
    # $DCRAW FLAGS
	# +M		use embedded color matrix
	# -H 4		Recover highlights by rebuilding them
	# -o 1		Output in sRGB colorspace
	# -q 3		Debayer with AHD algorithm
	# -T		Output TIFF    
    $DCRAW +M -H 4 -o 1 -q 3 -T "$@" "$MAIN_PICTURE.dng"

    # If imagemagick is available, convert the tiff to jpeg and apply slight sharpening
    if [ -n "$CONVERT" ];
    then
        if [ "$CONVERT" = "convert" ]; then
            convert "${MAIN_PICTURE}.${TIFF_EXT}" -sharpen 0x1.0 -sigmoidal-contrast 6,50% "${BURST_DIR}/main.${INTERNAL_EXTENSION}"
        else
            # sadly sigmoidal contrast is not available in imagemagick
            gm convert "${MAIN_PICTURE}.${TIFF_EXT}" -sharpen 0x1.0 "${BURST_DIR}/main.${INTERNAL_EXTENSION}"
        fi

        exiftool_function "${MAIN_PICTURE}.${TIFF_EXT}" "${BURST_DIR}/main.${INTERNAL_EXTENSION}"

        finalize_image "${BURST_DIR}/main.${INTERNAL_EXTENSION}" "${TARGET_NAME}"

        if [ -f "/etc/megapixels/auto_stack.py" ]; then
            for FILE in "${BURST_DIR}"/*.dng; do
                $DCRAW +M -H 4 -o 1 -q 3 -T "${FILE}"
            done

            # Remove original main conversion so it is not included in the stacking
            rm -f "${BURST_DIR}/main.${INTERNAL_EXTENSION}"

            python /etc/megapixels/auto_stack.py "${BURST_DIR}" "${BURST_DIR}/main_combined.${INTERNAL_EXTENSION}" --method ECC

            exiftool_function "${MAIN_PICTURE}.${TIFF_EXT}" "${BURST_DIR}/main_combined.${INTERNAL_EXTENSION}"

            finalize_image "${BURST_DIR}/main_combined.${INTERNAL_EXTENSION}" "${TARGET_NAME}_combined"
        fi

        echo "${TARGET_NAME}.${OUTPUT_EXTENSION}"
    else
        cp "${MAIN_PICTURE}.${TIFF_EXT}" "${TARGET_NAME}.tiff"

        echo "${TARGET_NAME}.tiff"
    fi
fi

# Clean up the temp dir containing the burst
rm -rf "$BURST_DIR"

# Clean up the .dng if the user didn't want it
if [ "$SAVE_DNG" -eq "0" ]; then
	rm "$TARGET_NAME.dng"
fi
