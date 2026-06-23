#!/bin/bash

# File Checker and Validator
TARGET_FILE="$1"

# Check if empty
if [[ -z "$TARGET_FILE" ]]; then
    echo "Error: Please input a text file as a variable."
    echo "Example: ./Apacible_final.sh filename"
    exit 1
fi

touch "$TARGET_FILE"

# Properly construct paths to avoid issues with subdirectories
TARGET_DIR=$(dirname "$TARGET_FILE")
TARGET_BASE=$(basename "$TARGET_FILE")

TEMP_FILE="${TARGET_DIR}/.${TARGET_BASE}.tmp"
cp "$TARGET_FILE" "$TEMP_FILE"

# Sanitize the file: Remove hidden Windows carriage returns (\r)
sed -i 's/\r$//' "$TEMP_FILE" 2>/dev/null

# CRITICAL FIX: Ensure file has at least one line so sed substitution works
if [[ ! -s "$TEMP_FILE" ]]; then
    echo "" > "$TEMP_FILE"
fi

# Main System Setup
ORIGINAL_STATE=$(stty -g)

# History System Setup
HISTORY_DIR="${TARGET_DIR}/.${TARGET_BASE}_history"
mkdir -p "$HISTORY_DIR"
UNDO_PTR=0
MAX_UNDO=0
cp "$TEMP_FILE" "$HISTORY_DIR/$UNDO_PTR"

# Cleanup trap uses ANSI clear (\e[H\e[2J) instead of the clear binary
trap 'stty "$ORIGINAL_STATE"; rm -f "$TEMP_FILE"; rm -rf "$HISTORY_DIR"; echo -en "\e[?7h\e[H\e[2J"' EXIT

# Terminal Dimensions & Resize Trap
update_dimensions() {
    ROWS=$(tput lines)
    COLS=$(tput cols)
    redraw_viewport
}
trap 'update_dimensions' WINCH
ROWS=$(tput lines)
COLS=$(tput cols)

# Viewport Initialization
TOP_ROW=1
cursor_x=1
cursor_y=1
CLIPBOARD=""

# --- Helper Functions ---

escape_for_sed() {
    printf '%s' "$1" | sed -e 's/[\\&~]/\\&/g'
}

redraw_viewport() {
    echo -en "\e[H\e[2J" # Faster, flicker-free clear
    BOTTOM_ROW=$(( TOP_ROW + ROWS - 1 ))
    sed -n "${TOP_ROW},${BOTTOM_ROW}p" "$TEMP_FILE"
    echo -en "\e[${cursor_y};${cursor_x}H"
}

save_state() {
    FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
    safe_line=$(escape_for_sed "$active_line")
    sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
    
    (( UNDO_PTR++ ))
    MAX_UNDO=$UNDO_PTR
    cp "$TEMP_FILE" "$HISTORY_DIR/$UNDO_PTR"
    
    # Keep only the last 30 undo states to prevent disk/inode bloat
    if (( UNDO_PTR > 30 )); then
        rm -f "$HISTORY_DIR/$(( UNDO_PTR - 31 ))"
    fi
}

# --- Initialization ---

FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")

redraw_viewport
echo -en "\e[?7l" # Disable line wrap
stty raw -echo

# --- Main Editor Loop ---
while true; do
    IFS= read -rsn1 char 

    # Enter key
    if [[ -z "$char" || "$char" == $'\x0d' || "$char" == $'\x0a' ]]; then
        save_state
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        
        safe_left=$(escape_for_sed "$left_side")
        safe_right=$(escape_for_sed "$right_side")
        
        # FIX: Use \n in substitution to avoid 'a\' stripping leading spaces
        sed -i "${FILE_Y}s~.*~${safe_left}\n${safe_right}~" "$TEMP_FILE"
        
        if (( cursor_y < ROWS )); then
            (( cursor_y++ ))
        else
            (( TOP_ROW++ ))
        fi
        
        cursor_x=1
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
        redraw_viewport
        continue
    fi

    # Tab key
    if [[ "$char" == $'\x09' ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        active_line="${left_side}    ${right_side}"
        
        echo -en "\e[${cursor_y};1H\e[2K$active_line"
        (( cursor_x += 4 ))
        echo -en "\e[${cursor_y};${cursor_x}H"
        continue
    fi

    # Printable characters
    if [[ "$char" =~ [[:print:]] ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        active_line="${left_side}${char}${right_side}"
        
        echo -en "\e[${cursor_y};1H\e[2K$active_line"
        (( cursor_x++ ))
        echo -en "\e[${cursor_y};${cursor_x}H"
        continue
    fi

    # Backspace
    if [[ "$char" == $'\x7f' ]]; then
        if (( cursor_x > 1 )); then
            left_side="${active_line:0:$((cursor_x - 2))}"
            right_side="${active_line:$((cursor_x - 1))}"
            active_line="${left_side}${right_side}"
            (( cursor_x-- ))
            
            echo -en "\e[${cursor_y};1H\e[2K$active_line"
            echo -en "\e[${cursor_y};${cursor_x}H"
        else
            FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
            if (( FILE_Y > 1 )); then
                save_state
                PREV_FILE_Y=$(( FILE_Y - 1 ))
                
                prev_line=$(sed -n "${PREV_FILE_Y}p" "$TEMP_FILE")
                new_cursor_x=$(( ${#prev_line} + 1 ))
                combined_line="${prev_line}${active_line}"
                
                safe_combined=$(escape_for_sed "$combined_line")
                sed -i "${PREV_FILE_Y}s~.*~${safe_combined}~" "$TEMP_FILE"
                sed -i "${FILE_Y}d" "$TEMP_FILE"
                
                if (( cursor_y > 1 )); then
                    (( cursor_y-- ))
                else
                    (( TOP_ROW-- ))
                fi
                
                cursor_x=$new_cursor_x
                active_line="$combined_line"
                redraw_viewport
            fi
        fi
        continue
    fi

    # Escape Sequences
    if [[ $char == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest
        if [[ "$rest" == "[3" ]]; then
            read -rsn1 -t 0.1 tilde
            rest="${rest}${tilde}"
        fi
        
        while read -rsn1 -t 0.01 discard; do :; done
        
        case "$rest" in
            "[A") # UP
                FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
                safe_line=$(escape_for_sed "$active_line")
                sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
                
                if (( cursor_y > 1 )); then
                    (( cursor_y-- ))
                elif (( TOP_ROW > 1 )); then
                    (( TOP_ROW-- ))
                    redraw_viewport
                fi
                
                FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
                active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
                if (( cursor_x > ${#active_line} + 1 )); then cursor_x=$(( ${#active_line} + 1 )); fi
                ;;
            "[B") # DOWN
                FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
                safe_line=$(escape_for_sed "$active_line")
                sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
                
                total_lines=$(sed -n '$=' "$TEMP_FILE")
                if (( FILE_Y >= total_lines )); then
                    echo "" >> "$TEMP_FILE"
                fi

                if (( cursor_y < ROWS )); then
                    (( cursor_y++ ))
                else
                    (( TOP_ROW++ ))
                    redraw_viewport
                fi
                
                FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
                active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
                if (( cursor_x > ${#active_line} + 1 )); then cursor_x=$(( ${#active_line} + 1 )); fi
                ;;
            "[C") # RIGHT
                if (( cursor_x < ${#active_line} + 1 )); then (( cursor_x++ )); fi
                ;;
            "[D") # LEFT
                if (( cursor_x > 1 )); then (( cursor_x-- )); fi
                ;;
            "[3~") # DELETE
                if (( cursor_x <= ${#active_line} )); then
                    left_side="${active_line:0:$((cursor_x - 1))}"
                    right_side="${active_line:$cursor_x}"
                    active_line="${left_side}${right_side}"
                    echo -en "\e[${cursor_y};1H\e[2K$active_line"
                else
                    FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
                    total_lines=$(sed -n '$=' "$TEMP_FILE")
                    if (( FILE_Y < total_lines )); then
                        save_state
                        NEXT_FILE_Y=$(( FILE_Y + 1 ))
                        next_line=$(sed -n "${NEXT_FILE_Y}p" "$TEMP_FILE")
                        combined_line="${active_line}${next_line}"
                        
                        safe_combined=$(escape_for_sed "$combined_line")
                        sed -i "${FILE_Y}s~.*~${safe_combined}~" "$TEMP_FILE"
                        sed -i "${NEXT_FILE_Y}d" "$TEMP_FILE"
                        
                        active_line="$combined_line"
                        redraw_viewport
                    fi
                fi
                ;;
        esac
        
        echo -en "\e[${cursor_y};${cursor_x}H"
        continue
    fi

    # Ctrl+O (Save)
    if [[ $char == $'\x0f' ]]; then
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        safe_line=$(escape_for_sed "$active_line")
        sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
        cp "$TEMP_FILE" "$TARGET_FILE"
        continue
    fi

    # Ctrl+K (Cut)
    if [[ $char == $'\x0b' ]]; then
        save_state
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        CLIPBOARD=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
        sed -i "${FILE_Y}d" "$TEMP_FILE"
        
        # Prevent cutting the last line from fully emptying the file and breaking sed
        if [[ ! -s "$TEMP_FILE" ]]; then echo "" > "$TEMP_FILE"; fi
        
        active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
        if (( cursor_x > ${#active_line} + 1 )); then cursor_x=$(( ${#active_line} + 1 )); fi
        redraw_viewport
        continue
    fi

    # Ctrl+U (Paste)
    if [[ $char == $'\x15' ]]; then
        if [[ -n "$CLIPBOARD" ]]; then
            save_state
            FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
            safe_clip=$(escape_for_sed "$CLIPBOARD")
            # FIX: safer newline injection instead of 'i\'
            sed -i "${FILE_Y}s~^~${safe_clip}\n~" "$TEMP_FILE"
            active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
            redraw_viewport
        fi
        continue
    fi

    # Ctrl+W (Undo)
    if [[ $char == $'\x17' ]]; then
        if (( UNDO_PTR > 0 && -f "$HISTORY_DIR/$((UNDO_PTR - 1))" )); then
            (( UNDO_PTR-- ))
            cp "$HISTORY_DIR/$UNDO_PTR" "$TEMP_FILE"
            FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
            active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
            if (( cursor_x > ${#active_line} + 1 )); then cursor_x=$(( ${#active_line} + 1 )); fi
            redraw_viewport
        fi
        continue
    fi

    # Ctrl+E (Redo)
    if [[ $char == $'\x05' ]]; then
        if (( UNDO_PTR < MAX_UNDO && -f "$HISTORY_DIR/$((UNDO_PTR + 1))" )); then
            (( UNDO_PTR++ ))
            cp "$HISTORY_DIR/$UNDO_PTR" "$TEMP_FILE"
            FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
            active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
            if (( cursor_x > ${#active_line} + 1 )); then cursor_x=$(( ${#active_line} + 1 )); fi
            redraw_viewport
        fi
        continue
    fi

    # Ctrl+X (Quit)
    if [[ $char == $'\x18' ]]; then
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        safe_line=$(escape_for_sed "$active_line")
        sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
        cp "$TEMP_FILE" "$TARGET_FILE"
        break
    fi
done