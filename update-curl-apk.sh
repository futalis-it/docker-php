#!/bin/bash

PROJECT_PATH="alpine%2Faports"  # alpine/aports
REMOTE_PATH="main/curl"
LOCAL_TARGET="./curl"
BRANCH="master"

mkdir -p "$LOCAL_TARGET"
rm "$LOCAL_TARGET"/*

# Get folder contents via API
curl -s "https://gitlab.alpinelinux.org/api/v4/projects/$PROJECT_PATH/repository/tree?path=$REMOTE_PATH&ref=$BRANCH" | \
jq -r '.[] | select(.type=="blob") | .path' | \
while read file_path; do
    # Download each file
    curl -s "https://gitlab.alpinelinux.org/api/v4/projects/$PROJECT_PATH/repository/files/$(echo "$file_path" | sed 's|/|%2F|g')/raw?ref=$BRANCH" \
         -o "$LOCAL_TARGET/$(basename "$file_path")"
done
