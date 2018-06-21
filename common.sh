#!/bin/bash

# common.sh - sharable functions for pcf usage report scripts
#
# Copyright (C) 2016  Rakuten, Inc.
# Copyright (C) 2018  Bright Zheng
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

p_index() {
    for i in "${!PROPERTIES_TO_SHOW_H[@]}"; do
       if [[ "${PROPERTIES_TO_SHOW_H[$i]}" == "$1" ]]; then
           echo $(($i+1))
       fi
    done
}

p_names_to_indexes() {
    IFS=','
    fields=()
    for f in $1; do
        if [[ $f =~ ^[0-9]+$ ]]; then
            fields+=($f)
        else
            fields+=($(p_index "$f"))
        fi
    done
    echo "${fields[*]}"
}

get_json () {
    next_url="$1"

    is_api_v2=false
    is_api_v3=false

    [[ ${next_url#/v2} != $next_url ]] && is_api_v2=true
    [[ ${next_url#/v3} != $next_url ]] && is_api_v3=true

    next_url_hash=$(echo "$next_url" "$cf_target" | $(which md5sum || which md5) | cut -d' ' -f1)
    cache_filename="/tmp/.$script_name.$user_id.$next_url_hash"

    if [[ $UPDATE_CACHE_MINUTES != "no_cache" ]]; then
        # Remove expired cache file
        find "$cache_filename" -maxdepth 0 -mmin +$UPDATE_CACHE_MINUTES -exec rm '{}' \; 2>/dev/null || true

        # Read from cache if exists
        if [[ -f "$cache_filename" ]]; then
            cat "$cache_filename"
            return
        fi
    fi

    output_all=()
    json_output=""
    current_page=0
    total_pages=0
    while [[ $next_url != null ]]; do
        # Get data
        json_data=$(cf curl "$next_url")

        # Show progress
        current_page=$((current_page + 1))
        if [[ $total_pages -eq 0 ]]; then
            if $is_api_v2; then
                total_pages=$(cf curl "$next_url" | jq '.total_pages')
            elif $is_api_v3; then
                total_pages=$(cf curl "$next_url" | jq '.pagination.total_pages')
            fi
        fi
        if $VERBOSE; then
            [[ $current_page -gt 1 ]] && echo -ne "\033[1A" >&2
            echo -e "Fetched page $current_page from $total_pages ( $next_url )\033[0K\r" >&2
        fi

        # Generate output
        if $is_api_v2; then
            output_current=$(echo "$json_data" | jq '[ .resources[] | {key: .metadata.guid, value: .} ] | from_entries')
        elif $is_api_v3; then
            output_current=$(echo "$json_data" | jq '[ .resources[] | {key: .guid, value: .} ] | from_entries')
        fi


        # Append current output to the result
        output_all+=("$output_current")

        # Get URL for next page of results
        if $is_api_v2; then
            next_url=$(echo "$json_data" | jq .next_url -r)
        elif $is_api_v3; then
            next_url=$(echo "$json_data" | jq .pagination.next.href -r | sed 's#^http\(s\?\)://[^/]\+/v3#/v3#')
        fi
    done
    json_output=$( (IFS=$'\n'; echo "${output_all[*]}") | jq -s 'add' )

    # Update cache file
    if [[ $UPDATE_CACHE_MINUTES != "no_cache" ]]; then
        echo "$json_output" > "$cache_filename"
    fi

    echo "$json_output"
}

f_format_date() {
    THE_DATE=$1;  # the date to format
    if [ "$(uname)" == "Darwin" ]; then
        echo $(date -j -f '%Y-%m-%d' "$THE_DATE" +'%Y-%m')      
    else
        echo $(date --date="$THE_DATE" +'%Y-%m')
    fi
}

f_next_month() {
    if [ "$(uname)" == "Darwin" ]; then
        echo $(date -j -f %Y-%m-%d -v+1m "$1" +%Y-%m) # YYYY-MM
    else
        echo $(date --date="$1 +1 months" +%Y-%m)
    fi
}

f_populate_dates() {
    START_DATE=$1;  # starting date
    TODAY=$(date +"%Y-%m-%d")
    YYYYMM=$(f_format_date "$START_DATE")
    END_DATE=$(f_month_last_date "$YYYYMM")

    while true;
    do
        #echo "$START_DATE -> $END_DATE: $TODAY"
        if [[ ! "$END_DATE" < "$TODAY" ]]; then
            A_START_DATES+=($START_DATE)
            A_END_DATES+=($TODAY)

            break
        else
            A_START_DATES+=($START_DATE)
            A_END_DATES+=($END_DATE)
        fi

        # next, +1 month
        YYYYMM=$(f_next_month "$YYYYMM-01")
        START_DATE="$YYYYMM-01";
        END_DATE=$(f_month_last_date "$YYYYMM");
    done
}

f_month_last_date() {
    if [ "$(uname)" == "Darwin" ]; then
        echo $(date -j -f %Y-%m-%d -v+1m -v-1d "$1-01" +%Y-%m-%d) # YYYY-MM
    else
        echo $(date --date="$1-01 +1 months -1 days" +%Y-%m-%d)
    fi
}

f_elementExists() {
    element=$1 && shift
	elements=($@)

    for e in "${elements[@]}"
    do
        if [[ "$e" = "$element" ]] ; then
            echo "true"
            return
        fi
    done

    echo "false"
}