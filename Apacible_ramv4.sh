#!/bin/bash

# ============================================================
# Micro — A fast, in-memory terminal text editor in pure Bash.
#
# All file data lives in a Bash array (FILE_LINES[]).
# Zero external processes are spawned during normal editing.
#
# Controls:
#   Ctrl+O    Save           Ctrl+X    Quit (auto-saves)
#   Ctrl+K    Cut line       Ctrl+U    Paste line
#   Ctrl+W    Undo           Ctrl+E    Redo
#   Arrows    Navigate       Home/End  Line start/end
#   PgUp/PgDn Page scroll    Tab       Insert 4 spaces
#   Delete    Forward delete Backspace  Backward delete
# ============================================================

# ========================
#  FILE VALIDATION & LOAD
# ========================

TARGET_FILE="$1"
if [[ -z "$TARGET_FILE" ]]; then
    echo "Error: No file specified."
    echo "Usage: ./Apacible_ramv2.sh <filename>"
    exit 1
fi

touch "$TARGET_FILE"

# Load entire file into a Bash array — this IS the data model
mapfile -t FILE_LINES < "$TARGET_FILE"

# Sanitize: strip Windows carriage returns (\r)
for i in "${!FILE_LINES[@]}"; do
    FILE_LINES[$i]="${FILE_LINES[$i]%$'\r'}"
done

# Ensure at least one line so the editor never crashes on empty files
if [[ ${#FILE_LINES[@]} -eq 0 ]]; then
    FILE_LINES+=("")
fi

# ========================
#  TERMINAL SETUP
# ========================

ORIGINAL_STATE=$(stty -g)

cleanup() {
    stty "$ORIGINAL_STATE"
    echo -en "\e[?7h"    # Re-enable line wrap
    echo -en "\e[?25h"   # Show cursor
    echo -en "\e[0m"     # Reset colors
    echo -en "\e[H\e[2J" # Clear screen
}
trap cleanup EXIT

# ========================
#  TERMINAL DIMENSIONS
# ========================

ROWS=$(tput lines)
COLS=$(tput cols)
EDIT_ROWS=$(( ROWS - 3 ))  # Reserve 3 chrome rows: title + status + shortcuts
if (( EDIT_ROWS < 1 )); then EDIT_ROWS=1; fi

# Handle terminal resize (SIGWINCH)
update_dimensions() {
    ROWS=$(tput lines)
    COLS=$(tput cols)
    EDIT_ROWS=$(( ROWS - 3 ))
    if (( EDIT_ROWS < 1 )); then EDIT_ROWS=1; fi
    if (( cursor_y > EDIT_ROWS )); then cursor_y=$EDIT_ROWS; fi
    full_refresh
}
trap 'update_dimensions' WINCH

# ========================
#  EDITOR STATE
# ========================

TOP_ROW=1         # 1-based index of the first visible line in the file
cursor_x=1        # 1-based column position in the logical line
cursor_y=1        # 1-based row position on the screen (within EDIT_ROWS)
LEFT_OFFSET=0     # Horizontal scroll: number of characters skipped from the left
CLIPBOARD=""      # Stores cut line content
HAS_CLIPBOARD=0   # Flag: has anything been cut?
MODIFIED=0        # Dirty flag: has the file been changed since last save?
STATUS_MSG=""     # Temporary status message (shown once, then cleared)

# ========================
#  UNDO/REDO SYSTEM
# ========================
#
# Snapshots are stored as serialized FILE_LINES arrays.
# A sentinel value ensures trailing empty lines are preserved.
# Snapshots are saved AFTER each structural edit (Enter, line merge,
# cut, paste, tab). Character-level edits are not individually tracked.
#
# UNDO_STACK[0] = initial file state
# UNDO_STACK[N] = state after the Nth structural edit

declare -a UNDO_STACK=()
UNDO_PTR=0
MAX_UNDO=0
UNDO_SENTINEL=$'\x1e'  # Record separator — safe non-printable delimiter

save_snapshot() {
    local tmp=("${FILE_LINES[@]}" "$UNDO_SENTINEL")
    local IFS=$'\x1f'
    UNDO_STACK[$UNDO_PTR]="${tmp[*]}"
}

restore_snapshot() {
    IFS=$'\x1f' read -ra FILE_LINES <<< "${UNDO_STACK[$UNDO_PTR]}"
    # Remove the sentinel element
    unset 'FILE_LINES[${#FILE_LINES[@]}-1]'
    # Safety: never let the array be completely empty
    if [[ ${#FILE_LINES[@]} -eq 0 ]]; then
        FILE_LINES+=("")
    fi
}

push_undo() {
    (( UNDO_PTR++ ))
    MAX_UNDO=$UNDO_PTR
    # Discard any redo states beyond current position
    local i=$((UNDO_PTR + 1))
    while [[ -n "${UNDO_STACK[$i]+set}" ]]; do
        unset 'UNDO_STACK[$i]'
        (( i++ ))
    done
    # Depth limit: keep the last 50 undo states
    if (( UNDO_PTR > 50 )); then
        unset 'UNDO_STACK[$((UNDO_PTR - 51))]'
    fi
}

# Save the initial file state as undo baseline
save_snapshot

# ========================
#  HORIZONTAL SCROLL
# ========================

adjust_scroll() {
    # When cursor fits within one screen-width, always show from the start
    if (( cursor_x <= COLS )); then
        LEFT_OFFSET=0
    # Cursor moved past right edge — scroll right
    elif (( cursor_x - LEFT_OFFSET > COLS )); then
        LEFT_OFFSET=$(( cursor_x - COLS ))
    # Cursor moved past left edge — scroll left
    elif (( cursor_x - LEFT_OFFSET < 1 )); then
        LEFT_OFFSET=$(( cursor_x - 1 ))
    fi
}

# ========================
#  DISPLAY FUNCTIONS
# ========================

# ESC byte for building buffered output (avoids echo -en interpreting file content)
ESC=$'\e'

# Redraw all visible lines into a single buffered write.
# Uses printf '%s' so backslashes in file content are never misinterpreted.
redraw_viewport() {
    local start_idx=$(( TOP_ROW - 1 ))
    local idx row buf=""

    for (( i=0; i<EDIT_ROWS; i++ )); do
        idx=$(( start_idx + i ))
        row=$(( i + 2 ))  # Row 1 is the title bar; content starts at row 2
        # Position + clear, then append visible content
        buf+="${ESC}[${row};1H${ESC}[2K"
        if (( idx < ${#FILE_LINES[@]} )); then
            buf+="${FILE_LINES[$idx]:$LEFT_OFFSET:$COLS}"
        fi
    done

    # Single write: terminal receives the entire frame at once
    printf '%s' "$buf"
}

# Draw the status bar (inverse video) — buffered into a single write
draw_status_bar() {
    local total=${#FILE_LINES[@]}
    local file_y=$(( TOP_ROW + cursor_y - 1 ))
    local fname
    fname=$(basename "$TARGET_FILE")
    local mod=""
    if (( MODIFIED )); then mod=" [+]"; fi

    # --- Status line (ROWS - 1) ---
    local info=" ${fname}${mod}  Ln ${file_y}/${total}  Col ${cursor_x}"
    local pad=$(( COLS - ${#info} ))
    if (( pad < 0 )); then pad=0; fi
    printf -v info "%s%*s" "$info" "$pad" ""

    # --- Shortcut hints (ROWS) ---
    local keys=" ^O Save | ^X Quit | ^K Cut | ^U Paste | ^W Undo | ^E Redo"
    pad=$(( COLS - ${#keys} ))
    if (( pad < 0 )); then pad=0; fi
    printf -v keys "%s%*s" "$keys" "$pad" ""

    # Single write for both bars
    printf '%s' "${ESC}[$((ROWS - 1));1H${ESC}[7m${info:0:$COLS}${ESC}[0m${ESC}[${ROWS};1H${ESC}[7m${keys:0:$COLS}${ESC}[0m"
}

# Draw the title bar on row 1 (inverse video, like nano)
draw_title_bar() {
    local fname
    fname=$(basename "$TARGET_FILE")
    local mod=""
    if (( MODIFIED )); then mod="Modified"; fi

    # Center the filename, put "Micro" on the left, modified on the right
    local left=" Micro"
    local right="${mod} "
    local center_space=$(( COLS - ${#left} - ${#right} - ${#fname} ))
    local lpad=$(( center_space / 2 ))
    if (( lpad < 1 )); then lpad=1; fi
    local rpad=$(( COLS - ${#left} - lpad - ${#fname} - ${#right} ))
    if (( rpad < 0 )); then rpad=0; fi

    local bar
    printf -v bar "%s%*s%s%*s%s" "$left" "$lpad" "" "$fname" "$rpad" "" "$right"
    printf '%s' "${ESC}[1;1H${ESC}[7m${bar:0:$COLS}${ESC}[0m"
}

# Flash a temporary status message (yellow bar, replaces status line for one cycle)
show_message() {
    local msg=" $1"
    local pad=$(( COLS - ${#msg} ))
    if (( pad < 0 )); then pad=0; fi
    printf -v msg "%s%*s" "$msg" "$pad" ""
    printf '%s' "${ESC}[$((ROWS - 1));1H${ESC}[30;43m${msg:0:$COLS}${ESC}[0m"
}

# Position the terminal cursor at the correct screen location
place_cursor() {
    local screen_col=$(( cursor_x - LEFT_OFFSET ))
    if (( screen_col < 1 )); then screen_col=1; fi
    if (( screen_col > COLS )); then screen_col=$COLS; fi
    local screen_row=$(( cursor_y + 1 ))  # +1 because row 1 is the title bar
    printf '%s' "${ESC}[${screen_row};${screen_col}H"
}

# Full refresh: hide cursor → redraw viewport + status → show cursor
# Cursor hiding is the #1 anti-flicker technique: prevents visible cursor jumping
full_refresh() {
    printf '%s' "${ESC}[?25l"  # Hide cursor FIRST
    adjust_scroll
    draw_title_bar
    redraw_viewport
    if [[ -n "$STATUS_MSG" ]]; then
        show_message "$STATUS_MSG"
        STATUS_MSG=""
    else
        draw_status_bar
    fi
    place_cursor
    printf '%s' "${ESC}[?25h"  # Show cursor LAST
}

# Fast single-line refresh: only redraws the current line + status bar
inline_refresh() {
    printf '%s' "${ESC}[?25l"  # Hide cursor
    adjust_scroll
    local idx=$(( TOP_ROW + cursor_y - 2 ))
    local screen_row=$(( cursor_y + 1 ))  # +1 for title bar
    # Use printf '%s' so file content with backslashes is printed literally
    printf '%s' "${ESC}[${screen_row};1H${ESC}[2K${FILE_LINES[$idx]:$LEFT_OFFSET:$COLS}"
    draw_status_bar
    place_cursor
    printf '%s' "${ESC}[?25h"  # Show cursor
}

# Lightest refresh: only update status bar + cursor position (no content redraw)
status_refresh() {
    printf '%s' "${ESC}[?25l"
    adjust_scroll
    draw_status_bar
    place_cursor
    printf '%s' "${ESC}[?25h"
}

# ========================
#  CURSOR CLAMPING HELPER
# ========================

clamp_cursor() {
    local total=${#FILE_LINES[@]}

    # Clamp cursor_y so it doesn't point past EOF
    if (( TOP_ROW + cursor_y - 2 >= total )); then
        cursor_y=$(( total - TOP_ROW + 1 ))
        if (( cursor_y < 1 )); then
            TOP_ROW=$total
            if (( TOP_ROW < 1 )); then TOP_ROW=1; fi
            cursor_y=1
        fi
    fi

    # Clamp cursor_x to line length + 1 (append position)
    local idx=$(( TOP_ROW + cursor_y - 2 ))
    local line_len=${#FILE_LINES[$idx]}
    if (( cursor_x > line_len + 1 )); then cursor_x=$(( line_len + 1 )); fi
    if (( cursor_x < 1 )); then cursor_x=1; fi
}

# ========================
#  INITIALIZATION
# ========================

echo -en "\e[?7l"      # Disable line wrap (prevents long-line corruption)
echo -en "\e[?25h"     # Ensure cursor is visible
echo -en "\e[H\e[2J"   # Clear screen for clean start
full_refresh
stty raw -echo          # Enter raw mode: every keystroke delivered immediately

# ========================
#  MAIN EDITOR LOOP
# ========================

while true; do
    IFS= read -rsn1 char

    current_idx=$(( TOP_ROW + cursor_y - 2 ))
    active_line="${FILE_LINES[$current_idx]}"

    # ───────────────────────────────────────────
    #  ENTER — Split line at cursor position
    # ───────────────────────────────────────────
    if [[ -z "$char" || "$char" == $'\x0d' || "$char" == $'\x0a' ]]; then
        push_undo
        MODIFIED=1

        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"

        FILE_LINES[$current_idx]="$left_side"
        FILE_LINES=(
            "${FILE_LINES[@]:0:$((current_idx + 1))}"
            "$right_side"
            "${FILE_LINES[@]:$((current_idx + 1))}"
        )

        if (( cursor_y < EDIT_ROWS )); then
            (( cursor_y++ ))
        else
            (( TOP_ROW++ ))
        fi
        cursor_x=1
        LEFT_OFFSET=0

        save_snapshot
        full_refresh
        continue
    fi

    # ───────────────────────────────────────────
    #  TAB — Insert 4 spaces
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x09' ]]; then
        push_undo
        MODIFIED=1

        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        FILE_LINES[$current_idx]="${left_side}    ${right_side}"
        (( cursor_x += 4 ))

        save_snapshot
        inline_refresh
        continue
    fi

    # ───────────────────────────────────────────
    #  PRINTABLE CHARACTERS — Insert at cursor
    # ───────────────────────────────────────────
    if [[ "$char" =~ [[:print:]] ]]; then
        left_side="${active_line:0:$((cursor_x - 1))}"
        right_side="${active_line:$((cursor_x - 1))}"
        FILE_LINES[$current_idx]="${left_side}${char}${right_side}"
        MODIFIED=1
        (( cursor_x++ ))

        inline_refresh
        continue
    fi

    # ───────────────────────────────────────────
    #  BACKSPACE — Delete character behind cursor
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x7f' ]]; then
        if (( cursor_x > 1 )); then
            # Same-line backspace: fast path, no undo snapshot
            left_side="${active_line:0:$((cursor_x - 2))}"
            right_side="${active_line:$((cursor_x - 1))}"
            FILE_LINES[$current_idx]="${left_side}${right_side}"
            MODIFIED=1
            (( cursor_x-- ))

            inline_refresh
        elif (( current_idx > 0 )); then
            # Cross-line backspace: merge with previous line (structural edit)
            push_undo
            MODIFIED=1

            prev_len=${#FILE_LINES[$((current_idx - 1))]}
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

            save_snapshot
            full_refresh
        fi
        continue
    fi

    # ───────────────────────────────────────────
    #  ESCAPE SEQUENCES — Arrows, Delete, Page, Home/End
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x1b' ]]; then
        read -rsn2 -t 0.1 rest

        # Extended sequences: read the trailing character (e.g., ~ for Delete)
        case "$rest" in
            "[3"|"[5"|"[6"|"[1"|"[4")
                read -rsn1 -t 0.1 tilde
                rest="${rest}${tilde}"
                ;;
        esac

        # Drain any remaining bytes from the sequence
        while read -rsn1 -t 0.01 discard; do :; done

        case "$rest" in

            # --- UP ARROW ---
            "[A")
                old_top=$TOP_ROW
                if (( cursor_y > 1 )); then
                    (( cursor_y-- ))
                elif (( TOP_ROW > 1 )); then
                    (( TOP_ROW-- ))
                fi

                new_idx=$(( TOP_ROW + cursor_y - 2 ))
                line_len=${#FILE_LINES[$new_idx]}
                if (( cursor_x > line_len + 1 )); then cursor_x=$(( line_len + 1 )); fi
                if (( cursor_x < 1 )); then cursor_x=1; fi

                # Only redraw viewport if we scrolled; otherwise just move cursor
                if (( TOP_ROW != old_top )); then
                    full_refresh
                else
                    status_refresh
                fi
                ;;

            # --- DOWN ARROW ---
            "[B")
                total_lines=${#FILE_LINES[@]}
                next_idx=$(( current_idx + 1 ))

                # Block at EOF: do NOT append blank lines (v1 bug fix)
                if (( next_idx >= total_lines )); then
                    place_cursor
                    continue
                fi

                old_top=$TOP_ROW
                if (( cursor_y < EDIT_ROWS )); then
                    (( cursor_y++ ))
                else
                    (( TOP_ROW++ ))
                fi

                new_idx=$(( TOP_ROW + cursor_y - 2 ))
                line_len=${#FILE_LINES[$new_idx]}
                if (( cursor_x > line_len + 1 )); then cursor_x=$(( line_len + 1 )); fi
                if (( cursor_x < 1 )); then cursor_x=1; fi

                if (( TOP_ROW != old_top )); then
                    full_refresh
                else
                    status_refresh
                fi
                ;;

            # --- RIGHT ARROW ---
            "[C")
                if (( cursor_x < ${#active_line} + 1 )); then
                    (( cursor_x++ ))
                    inline_refresh
                fi
                ;;

            # --- LEFT ARROW ---
            "[D")
                if (( cursor_x > 1 )); then
                    (( cursor_x-- ))
                    inline_refresh
                fi
                ;;

            # --- DELETE KEY ---
            "[3~")
                if (( cursor_x <= ${#active_line} )); then
                    # Same-line delete
                    left_side="${active_line:0:$((cursor_x - 1))}"
                    right_side="${active_line:$cursor_x}"
                    FILE_LINES[$current_idx]="${left_side}${right_side}"
                    MODIFIED=1

                    inline_refresh
                elif (( current_idx + 1 < ${#FILE_LINES[@]} )); then
                    # Cross-line delete: merge next line into current (structural)
                    push_undo
                    MODIFIED=1

                    FILE_LINES[$current_idx]="${active_line}${FILE_LINES[$((current_idx + 1))]}"
                    FILE_LINES=(
                        "${FILE_LINES[@]:0:$((current_idx + 1))}"
                        "${FILE_LINES[@]:$((current_idx + 2))}"
                    )

                    save_snapshot
                    full_refresh
                fi
                ;;

            # --- PAGE UP ---
            "[5~")
                (( TOP_ROW -= EDIT_ROWS ))
                if (( TOP_ROW < 1 )); then TOP_ROW=1; fi

                clamp_cursor
                full_refresh
                ;;

            # --- PAGE DOWN ---
            "[6~")
                total_lines=${#FILE_LINES[@]}
                (( TOP_ROW += EDIT_ROWS ))
                max_top=$(( total_lines - EDIT_ROWS + 1 ))
                if (( max_top < 1 )); then max_top=1; fi
                if (( TOP_ROW > max_top )); then TOP_ROW=$max_top; fi

                clamp_cursor
                full_refresh
                ;;

            # --- HOME ---
            "[H"|"[1~"|"OH")
                cursor_x=1
                LEFT_OFFSET=0
                inline_refresh
                ;;

            # --- END ---
            "[F"|"[4~"|"OF")
                cursor_x=$(( ${#active_line} + 1 ))
                inline_refresh
                ;;
        esac
        continue
    fi

    # ───────────────────────────────────────────
    #  Ctrl+O — SAVE
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x0f' ]]; then
        printf "%s\n" "${FILE_LINES[@]}" > "$TARGET_FILE"
        MODIFIED=0
        STATUS_MSG="Saved: $(basename "$TARGET_FILE") (${#FILE_LINES[@]} lines written)"
        full_refresh
        continue
    fi

    # ───────────────────────────────────────────
    #  Ctrl+K — CUT LINE
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x0b' ]]; then
        push_undo
        MODIFIED=1
        CLIPBOARD="${FILE_LINES[$current_idx]}"
        HAS_CLIPBOARD=1

        if (( ${#FILE_LINES[@]} > 1 )); then
            FILE_LINES=(
                "${FILE_LINES[@]:0:$current_idx}"
                "${FILE_LINES[@]:$((current_idx + 1))}"
            )
        else
            FILE_LINES=("")
        fi

        clamp_cursor
        save_snapshot
        full_refresh
        continue
    fi

    # ───────────────────────────────────────────
    #  Ctrl+U — PASTE LINE
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x15' ]]; then
        if (( HAS_CLIPBOARD )); then
            push_undo
            MODIFIED=1

            # Insert clipboard content above the current line
            FILE_LINES=(
                "${FILE_LINES[@]:0:$current_idx}"
                "$CLIPBOARD"
                "${FILE_LINES[@]:$current_idx}"
            )

            # Push cursor down to stay on the original line
            if (( cursor_y < EDIT_ROWS )); then
                (( cursor_y++ ))
            else
                (( TOP_ROW++ ))
            fi

            save_snapshot
            full_refresh
        fi
        continue
    fi

    # ───────────────────────────────────────────
    #  Ctrl+W — UNDO
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x17' ]]; then
        if (( UNDO_PTR > 0 )) && [[ -n "${UNDO_STACK[$((UNDO_PTR - 1))]+set}" ]]; then
            (( UNDO_PTR-- ))
            restore_snapshot

            clamp_cursor
            full_refresh
        fi
        continue
    fi

    # ───────────────────────────────────────────
    #  Ctrl+E — REDO
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x05' ]]; then
        if (( UNDO_PTR < MAX_UNDO )) && [[ -n "${UNDO_STACK[$((UNDO_PTR + 1))]+set}" ]]; then
            (( UNDO_PTR++ ))
            restore_snapshot

            clamp_cursor
            full_refresh
        fi
        continue
    fi

    # ───────────────────────────────────────────
    #  Ctrl+X — QUIT (auto-saves if modified)
    # ───────────────────────────────────────────
    if [[ "$char" == $'\x18' ]]; then
        if (( MODIFIED )); then
            printf "%s\n" "${FILE_LINES[@]}" > "$TARGET_FILE"
        fi
        break
    fi

done
