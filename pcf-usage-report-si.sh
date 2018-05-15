#!/bin/bash

# pcf-usage-report-si.sh - Generate detailed SI usage report for all orgs all months in one cli call
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

# Dependencies: cf; jq >= 1.5

# Given: 
#   1) the sys domain: "sys.pcf-gcp.abc.com"; 
#   2) starting from (YYYY-mm-dd): 2018-01-20
# Sample commands:
#   1) generate AI report for system domain of "sys.pcf-gcp.abc.com", starting from "2018-01-20"
#       ./pcf-usage-report-si.sh -D sys.pcf-gcp.abc.com -d "2018-01-20"
#   2) generate AI report for system domain of "sys.pcf-gcp.abc.com", starting from "2018-01-20", as JSON output
#       ./pcf-usage-report-si.sh -D sys.pcf-gcp.abc.com -d "2018-01-20" -j
#   3) generate AI report for system domain of "sys.pcf-gcp.abc.com", starting from "2018-01-20", for specified "dev" org only
#       ./pcf-usage-report-si.sh -D sys.pcf-gcp.abc.com -d "2018-01-20" -o dev
#   4) generate AI report for system domain of "sys.pcf-gcp.abc.com", starting from "2018-01-20", with specified fields only
#       ./pcf-usage-report-si.sh -D sys.pcf-gcp.abc.com -d "2018-01-20" -f year,month,org_name,duration_in_seconds,service_instance_name,service_name,service_plan_name,deleted
#   5) generate AI report for system domain of "sys.pcf-gcp.abc.com", starting from "2018-01-20", with specified fields and tab separated output for further processing
#       ./pcf-usage-report-si.sh -D sys.pcf-gcp.abc.com -d "2018-01-20" -N -f year,month,org_name,duration_in_seconds,service_instance_name,service_name,service_plan_name,deleted


set -euo pipefail
umask 0077

PROPERTIES_TO_SHOW_H=("#" year month org_guid org_name duration_in_seconds space_guid space_name service_instance_guid service_instance_name service_guid service_name service_plan_guid service_plan_name service_instance_creation deleted service_instance_deletion)
PROPERTIES_TO_SHOW=(.year .month .organization_guid .organization .duration_in_seconds .space_guid .space_name .service_instance_guid .service_instance_name .service_guid .service_name .service_plan_guid .service_plan_name .service_instance_creation .deleted .service_instance_deletion)

show_usage () {
    cat << EOF
Usage: $(basename "$0") [OPTION]...

  -s <sort field>           sort by specified field index or its name
  -S <sort field>           sort by specified field index or its name (numeric)
  -f <field1,field2,...>    show only fields specified by indexes or field names
  -c <minutes>              filter objects created within last <minutes>
  -u <minutes>              filter objects updated within last <minutes>
  -C <minutes>              filter objects created more than <minutes> ago
  -U <minutes>              filter objects updated more than <minutes> ago
  -k <minutes>              update cache if older than <minutes> (default: 10)
  -n                        ignore cache
  -N                        do not format output and keep it tab-separated (useful for further processing)
  -j                        print json (filter and sort options are not applied when -j is in use)
  -v                        verbose
  -o <org1,org2...>         a list of orgs to be used for usage generation, separated by commas
  -d                        usage calculation starting date, YYYY-MM-DD
  -h                        display this help and exit
EOF
}

P_TO_SHOW_H=$(echo "${PROPERTIES_TO_SHOW_H[*]}")
P_TO_SHOW=$(IFS=','; echo "${PROPERTIES_TO_SHOW[*]}")

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

# Process command line options
opt_sort_options=""
opt_sort_field=""
opt_created_minutes=""
opt_updated_minutes=""
opt_created_minutes_older_than=""
opt_updated_minutes_older_than=""
opt_cut_fields=""
opt_format_output=""
opt_update_cache_minutes=""
opt_print_json=""
opt_verbose=""
opt_orgs=""
while getopts "o:D:d:s:S:c:u:C:U:f:k:nNjvh" opt; do
    case $opt in
        s)  opt_sort_options="-k"
            opt_sort_field=$OPTARG
            ;;
        S)  opt_sort_options="-nk"
            opt_sort_field=$OPTARG
            ;;
        c)  opt_created_minutes=$OPTARG
            ;;
        u)  opt_updated_minutes=$OPTARG
            ;;
        C)  opt_created_minutes_older_than=$OPTARG
            ;;
        U)  opt_updated_minutes_older_than=$OPTARG
            ;;
        f)  opt_cut_fields=$OPTARG
            ;;
        k)  opt_update_cache_minutes=$OPTARG
            ;;
        N)  opt_format_output="false"
            ;;
        n)  opt_update_cache_minutes="no_cache"
            ;;
        j)  opt_print_json="true"
            ;;
        v)  opt_verbose="true"
            ;;
        d)  opt_start_date=$OPTARG
            ;;
        D)  opt_domain=$OPTARG
            ;;
        o)  opt_orgs=$OPTARG
            ;;
        h)
            show_usage
            exit 0
            ;;
        ?)
            show_usage >&2
            exit 1
            ;;
    esac
done

# Set verbosity
VERBOSE=${opt_verbose:-false}

# Set printing json option (default: false)
PRINT_JSON=${opt_print_json:-false}

# Set sorting options, default is '-k1' (See 'man sort')
if [[ -n $opt_sort_field ]]; then
    opt_sort_field=$(( $(p_names_to_indexes "$opt_sort_field") - 1 ))
fi
SORT_OPTIONS="${opt_sort_options:--k} ${opt_sort_field:-1},${opt_sort_field:-1}"

# Set cache update option (default: 10)
UPDATE_CACHE_MINUTES=${opt_update_cache_minutes:-10}

# Define command to cut specific fields
if [[ -z $opt_cut_fields ]]; then
    CUT_FIELDS="cat"
else
    opt_cut_fields=$(p_names_to_indexes "$opt_cut_fields")
    cut_fields_awk=$(echo "$opt_cut_fields" | sed 's/\([0-9][0-9]*\)/$\1/g; s/,/"\\t"/g')
    CUT_FIELDS='awk -F"\t" "{print $cut_fields_awk}"'
fi

# Define format output command
if [[ $opt_format_output == "false" ]]; then
    FORMAT_OUTPUT="cat"
else
    FORMAT_OUTPUT="column -ts $'\t'"
fi

# Post filter
POST_FILTER=""
if [[ -n $opt_created_minutes ]]; then
    POST_FILTER="$POST_FILTER . |
                 (.metadata.created_at | (now - fromdate) / 60) as \$created_min_ago |
                 select (\$created_min_ago < $opt_created_minutes) |"
fi
if [[ -n $opt_updated_minutes ]]; then
    POST_FILTER="$POST_FILTER . |
                 (.metadata.updated_at as \$updated_at | if \$updated_at != null then \$updated_at | (now - fromdate) / 60 else null end ) as \$updated_min_ago |
                 select (\$updated_min_ago != null) | select (\$updated_min_ago < $opt_updated_minutes) |"
fi
if [[ -n $opt_created_minutes_older_than ]]; then
    POST_FILTER="$POST_FILTER . |
                 (.metadata.created_at | (now - fromdate) / 60) as \$created_min_ago |
                 select (\$created_min_ago > $opt_created_minutes_older_than) |"
fi
if [[ -n $opt_updated_minutes_older_than ]]; then
    POST_FILTER="$POST_FILTER . |
                 (.metadata.updated_at as \$updated_at | if \$updated_at != null then \$updated_at | (now - fromdate) / 60 else null end ) as \$updated_min_ago |
                 select (\$updated_min_ago != null) | select (\$updated_min_ago > $opt_updated_minutes_older_than) |"
fi

# The following variables are used to generate cache file path
script_name=$(basename "$0")
user_id=$(id -u)
cf_target=$(cf target)

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

A_ORGS_ONLY=()
A_START_DATES=()
A_END_DATES=()

f_populate_dates() {
    START_DATE=$1;  # starting date
    TODAY=$(date +"%Y-%m-%d")
    YYYYMM=$(date -j -f '%Y-%m-%d' "$START_DATE" +'%Y-%m')
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
        YYYYMM=$(date -j -f %Y-%m-%d -v+1m "$YYYYMM-01" +%Y-%m)
        START_DATE="$YYYYMM-01";
        END_DATE=$(f_month_last_date "$YYYYMM"); 
    done
}

f_month_last_date() {
    echo $(date -j -f %Y-%m-%d -v+1m -v-1d "$1-01" +%Y-%m-%d) # YYYY-MM
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

get_usage_json () {
    org_json=$1
    org_guids=($(echo "$org_json" | jq '.organizations[].metadata.guid' | jq --raw-output 'split("\n") | .[]'))
    org_names=($(echo "$org_json" | jq '.organizations[].entity.name' | jq --raw-output 'split("\n") | .[]'))
    output_all=()
    json_output=""

    if [[ "${opt_orgs}" != "" ]]; then
        IFS=',' read -r -a A_ORGS_ONLY <<< "${opt_orgs}"
    fi

    CF_TOKEN=$(cf oauth-token)

    for g in "${!org_guids[@]}"; do

        # If desired orgs have been set, check if current org is in the desired orgs
        if [[ ${#A_ORGS_ONLY[@]} > 0 ]]; then
            desired=$(f_elementExists "${org_names[$g]}" "${A_ORGS_ONLY[@]}")
            if [[ "${desired}" = "false" ]]; then
                continue
            fi
        fi

        for i in "${!A_START_DATES[@]}"; do
            # Get data
            json_data=$(curl "https://app-usage.$opt_domain/organizations/${org_guids[$g]}/service_usages?start=${A_START_DATES[$i]}&end=${A_END_DATES[$i]}" \
                -k -s -H "authorization: $CF_TOKEN")
            
            # Generate output
            output_current=$(echo "$json_data" | jq '[ . | {key: .organization_guid, value: .} ] | from_entries')

            # Append current output to the result
            output_all+=("$output_current")
        done
    done

    #json_output=$( (IFS=$'\n'; echo "${output_all[*]}") | jq -s '.' )
    #json_output=$( (IFS=$'\n'; echo "${output_all[*]}") | jq -s 'add' )
    json_output=$( (IFS=$'\n'; echo "${output_all[@]:-}") | jq -s '.' )
    echo "$json_output"
}

# Get organizations
next_url="/v2/organizations?results-per-page=100"
json_organizations=$(get_json "$next_url" | jq "{organizations:.}")

# Get services
#next_url="/v2/services?results-per-page=100"
#json_services=$(get_json "$next_url" | jq "{services:.}")

# Get usage
f_populate_dates "$opt_start_date"
json_usage_si=$(get_usage_json "$json_organizations" | jq "{service_usages:.}")

# Add extra data to json_usage_si
json_usage_si=$(echo "$json_organizations"$'\n'"$json_usage_si" | \
     jq -s 'add' | \
     jq '.organizations as $organizations |
        .service_usages[] |
        .[] |= (
                .service_usages[].organization_guid = .organization_guid |
                .service_usages[].year = (.period_start|split("-")[0]) |
                .service_usages[].month=(.period_start|split("-")[1])
            ) |
        .[].service_usages[] |= (
                .organization = $organizations[.organization_guid].entity.name
            ) |
        .[].service_usages[]' | \
    jq -s '.')

if $PRINT_JSON; then
    echo "$json_usage_si"
else
    # Generate service instances list (tab-delimited)
    json_usage_si_list=$(echo "$json_usage_si" |\
        jq -r ".[] |
            $POST_FILTER
            [ $P_TO_SHOW | select (. == null) = \"<null>\" | select (. == \"\") = \"<empty>\" ] |
            @tsv")

    if [[ $opt_format_output == "false" ]]; then
        # Print headers and app_list
        (echo $P_TO_SHOW_H | tr ' ' '\t'; echo -n "$json_usage_si_list" | sort -t $'\t' $SORT_OPTIONS | nl -w4) | \
            # Cut fields
            eval $CUT_FIELDS | \
            # Format columns for nice output
            eval $FORMAT_OUTPUT
    else
        # Print headers and app_list
        (echo $P_TO_SHOW_H | tr ' ' '\t'; echo -n "$json_usage_si_list" | sort -t $'\t' $SORT_OPTIONS | nl -w4) | \
            # Cut fields
            eval $CUT_FIELDS | \
            # Format columns for nice output
            eval $FORMAT_OUTPUT | less --quit-if-one-screen --no-init --chop-long-lines
    fi

fi
