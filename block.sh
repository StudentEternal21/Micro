#!/bin/bash

TARGET_FILE=$1

if [[ -z "$TARGET_FILE"  || !("$TARGET_FILE" =~ \.txt$) ]]; then
    echo "Error: Please input a text file as a variable."
    echo "Example: Apacible_final.sh text.txt"
    exit 1
else 
    touch "$TARGET_FILE"
    TEMP_FILE="${TARGET_FILE}.tmp"
    cp "$TARGET_FILE" "$TEMP_FILE"
    
fi