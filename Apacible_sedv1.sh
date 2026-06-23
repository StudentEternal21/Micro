#!/bin/bash

# File Checker and Validator
TARGET_FILE="$1"

# Check if empty, or if it does NOT end in .txt
if [[ -z "$TARGET_FILE" || ! "$TARGET_FILE" =~ \.txt$ ]]; then
    echo "Error: Please input a text file as a variable."
    echo "Example: ./Apacible_final.sh text.txt"
    exit 1
else 
    touch "$TARGET_FILE"
    
    # Properly construct paths to avoid issues with subdirectories
    TARGET_DIR=$(dirname "$TARGET_FILE")
    TARGET_BASE=$(basename "$TARGET_FILE")
    
    TEMP_FILE="${TARGET_DIR}/.${TARGET_BASE}.tmp"
    cp "$TARGET_FILE" "$TEMP_FILE"
    
    # Sanitize the file: Remove hidden Windows carriage returns (\r) to prevent screen tearing
    sed -i 's/\r$//' "$TEMP_FILE" 2>/dev/null
fi

# Main System Setup
ORIGINAL_STATE=$(stty -g)

# History System Setup
HISTORY_DIR="${TARGET_DIR}/.${TARGET_BASE}_history"
mkdir -p "$HISTORY_DIR"
UNDO_PTR=0
MAX_UNDO=0
# Save the initial state as snapshot 0
cp "$TEMP_FILE" "$HISTORY_DIR/$UNDO_PTR"

# Ensure all temporary files and directories are wiped on exit (except on a clean Ctrl+X save)
# Added \e[?7h to re-enable terminal line wrapping when the program exits
trap 'stty "$ORIGINAL_STATE"; rm -f "$TEMP_FILE"; rm -rf "$HISTORY_DIR"; echo -en "\e[?7h"; clear' EXIT

ROWS=$(tput lines)
COLS=$(tput cols)

# Viewport Initialization
TOP_ROW=1

# --- Helper Functions ---

# Escapes special characters (\, &, ~) so sed doesn't corrupt the file or break the command
escape_for_sed() {
    printf '%s' "$1" | sed -e 's/[\\&~]/\\&/g'
}

# Refreshes the screen after major changes
redraw_viewport() {
    clear
    echo -en "\e[H"
    BOTTOM_ROW=$(( TOP_ROW + ROWS - 1 ))
    sed -n "${TOP_ROW},${BOTTOM_ROW}p" "$TEMP_FILE"
    echo -en "\e[${cursor_y};${cursor_x}H"
}

# Saves the current file state before making a destructive change
save_state() {
    FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
    safe_line=$(escape_for_sed "$active_line")
    sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
    
    (( UNDO_PTR++ ))
    MAX_UNDO=$UNDO_PTR
    cp "$TEMP_FILE" "$HISTORY_DIR/$UNDO_PTR"
}

# --- Initialization ---

cursor_x=1
cursor_y=1
CLIPBOARD=""

# Load the first line of text into Bash memory so we are ready to edit it
FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")

# Load the initial view
redraw_viewport

# Enter Editor Mode
# \e[?7l disables visual line wrapping so long lines don't break our math
echo -en "\e[?7l"
stty raw -echo

# The infinite loop keeps the script alive
while true; do
    # Listen for keystrokes
    IFS= read -rsn1 char 

    # Listen for the Enter key (ASCII 13 / \x0d or empty string)
    if [[ -z "$char" || "$char" == $'\x0d' || "$char" == $'\x0a' ]]; then
        save_state
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        
        # Replace current row with the safe left side
        safe_left=$(escape_for_sed "$left_side")
        sed -i "${FILE_Y}s~.*~${safe_left}~" "$TEMP_FILE"
        
        # Use G for empty right sides, otherwise append normally
        if [[ -z "$right_side" ]]; then
            sed -i "${FILE_Y}G" "$TEMP_FILE"
        else
            sed -i "${FILE_Y}a\\${right_side}" "$TEMP_FILE"
        fi
        
        # Move terminal cursor down
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

    # Listen for the Tab key (ASCII 9 / \x09)
    if [[ "$char" == $'\x09' ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        
        # Insert 4 spaces instead of a literal tab character
        active_line="${left_side}    ${right_side}"
        
        echo -en "\e[${cursor_y};1H\e[2K$active_line"
        (( cursor_x += 4 ))
        echo -en "\e[${cursor_y};${cursor_x}H"
        
        continue
    fi

    # Check if the key pressed is a regular, printable character
    if [[ "$char" =~ [[:print:]] ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        
        active_line="${left_side}${char}${right_side}"
        
        echo -en "\e[${cursor_y};1H\e[2K$active_line"
        (( cursor_x++ ))
        echo -en "\e[${cursor_y};${cursor_x}H"
        
        continue
    fi

    # Listen for the Backspace signal (ASCII 127)
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

    # Check if the keystroke was an Escape sequence (like an arrow key or Delete key)
    if [[ $char == $'\x1b' ]]; then
        
        read -rsn2 -t 0.1 rest
        
        # If the sequence starts with [3, we need to read one more byte to catch the ~ for Delete
        if [[ "$rest" == "[3" ]]; then
            read -rsn1 -t 0.1 tilde
            rest="${rest}${tilde}"
        fi
        
        # Flush any trailing bytes from longer escape sequences
        while read -rsn1 -t 0.01 discard; do :; done
        
        case "$rest" in
            "[A") # UP Arrow
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
                
                # Clamp cursor X to the new line's bounds
                if (( cursor_x > ${#active_line} + 1 )); then
                    cursor_x=$(( ${#active_line} + 1 ))
                fi
                ;;
            "[B") # DOWN Arrow
                FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
                safe_line=$(escape_for_sed "$active_line")
                sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
                
                # Use sed -n '$=' for accurate line counts regardless of trailing newlines
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
                
                # Clamp cursor X to the new line's bounds
                if (( cursor_x > ${#active_line} + 1 )); then
                    cursor_x=$(( ${#active_line} + 1 ))
                fi
                ;;
            "[C") # RIGHT Arrow
                # Clamp Right Arrow to line length
                if (( cursor_x < ${#active_line} + 1 )); then
                    (( cursor_x++ ))
                fi
                ;;
            "[D") # LEFT Arrow
                if (( cursor_x > 1 )); then
                    (( cursor_x-- ))
                fi
                ;;
            "[3~") # DELETE Key (Forward delete)
                if (( cursor_x <= ${#active_line} )); then
                    # Delete the character at the current cursor position
                    left_side="${active_line:0:$((cursor_x - 1))}"
                    right_side="${active_line:$cursor_x}"
                    
                    active_line="${left_side}${right_side}"
                    
                    echo -en "\e[${cursor_y};1H\e[2K$active_line"
                else
                    # Cursor is at the end of the line, pull the next line up
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

    # --- Advanced Keyboard Shortcuts ---

    # Ctrl+O (\x0f) - Save Mid-Session
    if [[ $char == $'\x0f' ]]; then
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        safe_line=$(escape_for_sed "$active_line")
        sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
        cp "$TEMP_FILE" "$TARGET_FILE"
        continue
    fi

    # Ctrl+K (\x0b) - Cut Line
    if [[ $char == $'\x0b' ]]; then
        save_state
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        CLIPBOARD=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
        sed -i "${FILE_Y}d" "$TEMP_FILE"
        
        active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
        
        # Clamp cursor X if new line is shorter
        if (( cursor_x > ${#active_line} + 1 )); then
            cursor_x=$(( ${#active_line} + 1 ))
        fi
        
        redraw_viewport
        continue
    fi

    # Ctrl+U (\x15) - Paste Line
    if [[ $char == $'\x15' ]]; then
        if [[ -n "$CLIPBOARD" ]]; then
            save_state
            FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
            sed -i "${FILE_Y}i\\${CLIPBOARD}" "$TEMP_FILE"
            active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
            redraw_viewport
        fi
        continue
    fi

    # Ctrl+W (\x17) - Undo
    if [[ $char == $'\x17' ]]; then
        if (( UNDO_PTR > 0 )); then
            (( UNDO_PTR-- ))
            cp "$HISTORY_DIR/$UNDO_PTR" "$TEMP_FILE"
            FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
            active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
            
            if (( cursor_x > ${#active_line} + 1 )); then
                cursor_x=$(( ${#active_line} + 1 ))
            fi
            
            redraw_viewport
        fi
        continue
    fi

    # Ctrl+E (\x05) - Redo
    if [[ $char == $'\x05' ]]; then
        if (( UNDO_PTR < MAX_UNDO )); then
            (( UNDO_PTR++ ))
            cp "$HISTORY_DIR/$UNDO_PTR" "$TEMP_FILE"
            FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
            active_line=$(sed -n "${FILE_Y}p" "$TEMP_FILE")
            
            if (( cursor_x > ${#active_line} + 1 )); then
                cursor_x=$(( ${#active_line} + 1 ))
            fi
            
            redraw_viewport
        fi
        continue
    fi

    # Ctrl+X (\x18) - Quit command and Save
    if [[ $char == $'\x18' ]]; then
        FILE_Y=$(( TOP_ROW + cursor_y - 1 ))
        safe_line=$(escape_for_sed "$active_line")
        sed -i "${FILE_Y}s~.*~${safe_line}~" "$TEMP_FILE"
        cp "$TEMP_FILE" "$TARGET_FILE"
        break
    fi
done