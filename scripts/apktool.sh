#!/usr/bin/env bash
#
# Copyright (C) 2025 Salvo Giangreco
# Updated 2026 for Dex 31 compatibility
#

# [
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1

FRAMEWORK_DIR="$TOOLS_DIR/apktool/framework"
FRAMEWORK_TAG="$(GET_PROP "system" "ro.build.version.incremental")"

FORCE=false
PARTITION=""
FILE=""

INPUT_FILE=""
OUTPUT_PATH=""
ARGS=""

THREAD_COUNT=$(awk -v max="$(nproc)" '/MemTotal/ {
  tc = int(($2 + 1048575) / 2097152);
  print (tc < 1 ? 1 : (tc > max ? max : tc));
}' /proc/meminfo)

[ -n "$GITHUB_ACTIONS" ] && THREAD_COUNT=1

BUILD()
{
    if [ ! -d "$OUTPUT_PATH" ]; then
        LOGE "Folder not found: ${OUTPUT_PATH//$SRC_DIR\//}"
        exit 1
    fi

    LOG "- Building ${INPUT_FILE//$WORK_DIR/}"

    if [ -d "$OUTPUT_PATH/smali" ]; then
        local DEX_API_LEVEL
        local DEX_FILENAME

        while IFS= read -r d; do
            DEX_API_LEVEL="$(cat "$OUTPUT_PATH/dex_api_version" 2> /dev/null)"

            if [ ! "$DEX_API_LEVEL" ] || [[ "$DEX_API_LEVEL" -gt "35" ]]; then
                LOGE "Invalid DEX API level: $DEX_API_LEVEL"
                exit 1
            fi

            if [[ "$d" == *"smali" ]]; then
                DEX_FILENAME="classes.dex"
            else
                DEX_FILENAME="$(basename "${d//smali_/}").dex"
            fi

            EVAL "smali a -a \"$DEX_API_LEVEL\" -j \"$THREAD_COUNT\" -o \"$OUTPUT_PATH/$DEX_FILENAME\" \"$d\"" &
        done < <(find "$OUTPUT_PATH" -maxdepth 1 -type d -name "smali*")

        wait $(jobs -p) || exit 1
    fi

    mkdir -p "$OUTPUT_PATH/build/apk"
    cp -a "$OUTPUT_PATH/original/META-INF" "$OUTPUT_PATH/build/apk/META-INF"

    EVAL "apktool b -j \"$THREAD_COUNT\" -p \"$FRAMEWORK_DIR\" \"$OUTPUT_PATH\"" || exit 1

    find "$OUTPUT_PATH" -maxdepth 1 -type f -name "*.dex" -delete

    local FILE_NAME
    FILE_NAME="$(basename "$INPUT_FILE")"

    if [[ "$INPUT_FILE" == *".apk" ]]; then
        local CERT_PREFIX="aosp"
        $ROM_IS_OFFICIAL && CERT_PREFIX="extremerom"

        LOG "- Signing ${INPUT_FILE//$WORK_DIR/}"
        EVAL "signapk \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$OUTPUT_PATH/dist/$FILE_NAME\" \"$OUTPUT_PATH/dist/temp.apk\"" || exit 1
        mv -f "$OUTPUT_PATH/dist/temp.apk" "$OUTPUT_PATH/dist/$FILE_NAME"
    else
        LOG "- Zipaligning ${INPUT_FILE//$WORK_DIR/}"
        EVAL "zipalign -p 4 \"$OUTPUT_PATH/dist/$FILE_NAME\" \"$OUTPUT_PATH/dist/temp\"" || exit 1
        mv -f "$OUTPUT_PATH/dist/temp" "$OUTPUT_PATH/dist/$FILE_NAME"
    fi

    mkdir -p "$(dirname "$INPUT_FILE")"
    mv -f "$OUTPUT_PATH/dist/$FILE_NAME" "$INPUT_FILE"
    rm -rf "$OUTPUT_PATH/build" && rm -rf "$OUTPUT_PATH/dist"
}

DECODE()
{
    if [ ! -f "$INPUT_FILE" ]; then
        LOGE "File not found: ${INPUT_FILE//$WORK_DIR/}"
        exit 1
    elif [ -d "$OUTPUT_PATH" ]; then
        if $FORCE; then
            rm -rf "$OUTPUT_PATH"
        else
            LOGE "Output directory already exists. Use --force."
            exit 1
        fi
    fi

    LOG "- Decoding ${INPUT_FILE//$WORK_DIR/}"
    EVAL "apktool d -b -j \"$THREAD_COUNT\" -o \"$OUTPUT_PATH\" -p \"$FRAMEWORK_DIR\" -t \"$FRAMEWORK_TAG\" -s \"$INPUT_FILE\"" || exit 1

    if [ -f "$OUTPUT_PATH/classes.dex" ]; then
        local DEX_API_LEVEL
        local SMALI_OUT

        while IFS= read -r f; do
            DEX_API_LEVEL="$(DEX_TO_API "$f")"
            [ "$DEX_API_LEVEL" ] || exit 1
            echo -n "$DEX_API_LEVEL" > "$OUTPUT_PATH/dex_api_version"

            if [[ "$f" == *"classes.dex" ]]; then
                SMALI_OUT="smali"
            else
                SMALI_OUT="smali_$(basename "${f//.dex/}")"
            fi

            EVAL "baksmali d -a \"$DEX_API_LEVEL\" --ac false --di false -j \"$THREAD_COUNT\" -l -o \"$OUTPUT_PATH/$SMALI_OUT\" --sl \"$f\"" &
        done < <(find "$OUTPUT_PATH" -maxdepth 1 -type f -name "*.dex")

        wait $(jobs -p) || exit 1
        find "$OUTPUT_PATH" -maxdepth 1 -type f -name "*.dex" -delete
    fi
}

DEX_TO_API()
{
    local DEX_FILE="$1"
    local DEX_VERSION
    DEX_VERSION="$(READ_BYTES_AT "$DEX_FILE" "6" "1")"

    local API
    case "$DEX_VERSION" in
        "31")
            API="31" # Added for S22 Dec 2025/2026 support
            ;;
        "35")
            API="23"
            ;;
        "37")
            API="25"
            ;;
        "38")
            API="27"
            ;;
        "39")
            API="29"
            ;;
        "40")
            API="34"
            ;;
        "41")
            API="35"
            ;;
        *)
            # Fallback instead of ABORT to let kernel build proceed
            LOGW "Unknown DEX ($DEX_VERSION) in ${DEX_FILE##*/}. Defaulting to API 31."
            API="31"
            ;;
    esac
    echo "$API"
}

PREPARE_SCRIPT()
{
    ACTION="$1"
    shift
    if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
        FORCE=true
        shift
    fi
    PARTITION="$1"
    shift
    FILE="$1"
    INPUT_FILE="$WORK_DIR/$PARTITION/$FILE"
    OUTPUT_PATH="$APKTOOL_DIR/$PARTITION/${FILE//system\//}"
}
# ]

ACTION=""
PREPARE_SCRIPT "$@"

if [ ! -f "$FRAMEWORK_DIR/1-$FRAMEWORK_TAG.apk" ]; then
    EVAL "apktool if -p \"$FRAMEWORK_DIR\" -t \"$FRAMEWORK_TAG\" \"$WORK_DIR/system/system/framework/framework-res.apk\"" || exit 1
fi

case "$ACTION" in
    "d" | "decode") DECODE ;;
    "b" | "build") BUILD ;;
esac

exit 0
