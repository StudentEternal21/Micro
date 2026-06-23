#!/bin/bash

# File Checker and Validator
TARGET_FILE="$1"

if [[ -z "$TARGET_FILE" ]]; then
    echo "Error: Please input a text file as a variable."
    echo "Example: ./editor.sh filename"
    exit 1
fi

touch "$TARGET_FILE"

# Load the entire file into a Bash array. '-t' removes trailing newlines.
mapfile -t FILE_LINES < "$TARGET_FILE"

# Ensure the array has at least one element so the editor does not crash on empty files
if [[ ${#FILE_LINES[@]} -eq 0 ]]; then
    FILE_LINES+=("")
fi

# Main System Setup
ORIGINAL_STATE=$(stty -g)

# Cleanup trap
trap 'stty "$ORIGINAL_STATE"; echo -en "\e[?7h\e[H\e[2J"' EXIT

# Terminal Dimensions
ROWS=$(tput lines)
COLS=$(tput cols)

# Viewport Initialization
TOP_ROW=1
cursor_x=1
cursor_y=1
CLIPBOARD=""

# --- Helper Functions ---

redraw_viewport() {
    echo -en "\e[H\e[2J" # Faster, flicker-free clear
    
    start_idx=$(( TOP_ROW - 1 ))
    
    # Print the visible slice of the array
    for (( i=0; i<ROWS; i++ )); do
        idx=$(( start_idx + i ))
        if (( idx < ${#FILE_LINES[@]} )); then
            # \r\n is required in raw mode to return the carriage to column 1
            echo -en "${FILE_LINES[$idx]}\r\n"
        else
            echo -en "\r\n"
        fi
    done
    
    # Place cursor back at its active position
    echo -en "\e[${cursor_y};${cursor_x}H"
}

# --- Initialization ---
redraw_viewport
echo -en "\e[?7l" # Disable line wrap
stty raw -echo

# --- Main Editor Loop ---
while true; do
    IFS= read -rsn1 char 
    current_idx=$(( TOP_ROW + cursor_y - 2 ))
    active_line="${FILE_LINES[$current_idx]}"

    # Enter key
    if [[ -z "$char" || "$char" == $'\x0d' || "$char" == $'\x0a' ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        
        # Current line becomes just the left side
        FILE_LINES[$current_idx]="$left_side"
        
        # Splice the array to insert the new line
        FILE_LINES=(
            "${FILE_LINES[@]:0:$((current_idx + 1))}"
            "$right_side"
            "${FILE_LINES[@]:$((current_idx + 1))}"
        )
        
        if (( cursor_y < ROWS )); then
            (( cursor_y++ ))
        else
            (( TOP_ROW++ ))
        fi
        
        cursor_x=1
        redraw_viewport
        continue
    fi

    # Tab key (Hardcoded 4 spaces for simplicity)
    if [[ "$char" == $'\x09' ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        
        FILE_LINES[$current_idx]="${left_side}    ${right_side}"
        
        # \r brings us to the start of the line, \e[2K clears it, then we print
        echo -en "\r\e[${cursor_y};1H\e[2K${FILE_LINES[$current_idx]}"
        (( cursor_x += 4 ))
        echo -en "\e[${cursor_y};${cursor_x}H"
        continue
    fi

    # Printable characters
    if [[ "$char" =~ [[:print:]] ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        
        FILE_LINES[$current_idx]="${left_side}${char}${right_side}"
        
        echo -en "\r\e[${cursor_y};1H\e[2K${FILE_LINES[$current_idx]}"
        (( cursor_x++ ))
        echo -en "\e[${cursor_y};${cursor_x}H"
        continue
    fi

    # Backspace
    if [[ "$char" == $'\x7f' ]]; then
        if (( cursor_x > 1 )); then
            left_side="${active_line:0:$((cursor_x - 2))}"
            right_side="${active_line:$((cursor_x - 1))}"
            
            FILE_LINES[$current_idx]="${left_side}${right_side}"
            (( cursor_x-- ))
            
            echo -en "\r\e[${cursor_y};1H\e[2K${FILE_LINES[$current_idx]}"
            echo -en "\e[${cursor_y};${cursor_x}H"
        else
            if (( current_idx > 0 )); then
                prev_len=${#FILE_LINES[$((current_idx - 1))]}
                
                # Merge current line into previous line
                FILE_LINES[$((current_idx - 1))]="${FILE_LINES[$((current_idx - 1))]}${active_line}"
                
                # Remove current line from array
                FILE_LINES=(
                    "${FILE_LINES[@]:0:$current_idx}"
                    "${FILE_LINES[@]:$((current_idx + 1))}"
                )
                
                if (( cursor_y > 1 )); then
                    (( cursor_y-- ))
                else
                    (( TOP_ROW-- ))
                fi
                
                cursor_x=$(( prev_len + 1 ))
                redraw_viewport
            fi
        fi
        continue
    fi

    # Escape Sequences (Arrows and Delete)
    if [[ $char == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest
        if [[ "$rest" == "[3" ]]; then
            read -rsn1 -t 0.1 tilde
            rest="${rest}${tilde}"
        fi
        
        while read -rsn1 -t 0.01 discard; do :; done
        
        case "$rest" in
            "[A") # UP
                if (( cursor_y > 1 )); then
                    (( cursor_y-- ))
                elif (( TOP_ROW > 1 )); then
                    (( TOP_ROW-- ))
                    redraw_viewport
                fi
                
                new_idx=$(( TOP_ROW + cursor_y - 2 ))
                line_len=${#FILE_LINES[$new_idx]}
                if (( cursor_x > line_len + 1 )); then cursor_x=$(( line_len + 1 )); fi
                ;;
            "[B") # DOWN
                total_lines=${#FILE_LINES[@]}
                if (( current_idx + 1 >= total_lines )); then
                    FILE_LINES+=("") # Append empty line at EOF if pushing down
                fi

                if (( cursor_y < ROWS )); then
                    (( cursor_y++ ))
                else
                    (( TOP_ROW++ ))
                    redraw_viewport
                fi
                
                new_idx=$(( TOP_ROW + cursor_y - 2 ))
                line_len=${#FILE_LINES[$new_idx]}
                if (( cursor_x > line_len + 1 )); then cursor_x=$(( line_len + 1 )); fi
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
                    FILE_LINES[$current_idx]="${left_side}${right_side}"
                    
                    echo -en "\r\e[${cursor_y};1H\e[2K${FILE_LINES[$current_idx]}"
                else
                    total_lines=${#FILE_LINES[@]}
                    if (( current_idx + 1 < total_lines )); then
                        # Merge next line into current line
                        FILE_LINES[$current_idx]="${active_line}${FILE_LINES[$((current_idx + 1))]}"
                        
                        # Delete next line from array
                        FILE_LINES=(
                            "${FILE_LINES[@]:0:$((current_idx + 1))}"
                            "${FILE_LINES[@]:$((current_idx + 2))}"
                        )
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
        # printf maps nicely to arrays, adding a newline to each element
        printf "%s\n" "${FILE_LINES[@]}" > "$TARGET_FILE"
        continue
    fi

    # Ctrl+X (Quit)
    if [[ $char == $'\x18' ]]; then
        break
    fi
done