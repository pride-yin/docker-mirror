#!/bin/bash
set -eu

IMAGES_FILE="images.txt"
SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
FAILED_IMAGES=()

retry_command() {
    local max_attempts=2
    local delay=5
    local attempt=1
    local command="$@"

    if [[ "$command" == *"ghcr.io"* ]] || [[ "$command" == *"quay.io"* ]]; then
        max_attempts=4
        delay=8
    fi

    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt/$max_attempts"
        if eval "$command"; then
            echo "Command succeeded"
            return 0
        else
            local exit_code=$?
            echo "Command failed with exit code: $exit_code"
            if [ $attempt -lt $max_attempts ]; then
                echo "Retrying in ${delay} seconds..."
                sleep $delay
                if [[ "$command" == *"ghcr.io"* ]] || [[ "$command" == *"quay.io"* ]]; then
                    delay=$((delay + 3))
                else
                    delay=$((delay * 2))
                fi
            fi
            attempt=$((attempt + 1))
        fi
    done

    echo "Command failed after $max_attempts attempts"
    return 1
}

if [ ! -f "$IMAGES_FILE" ]; then
    echo "Error: images.txt not found!"
    exit 1
fi

if [ -z "$ACR_REGISTRY" ] || [ -z "$ACR_NAMESPACE" ]; then
    echo "Error: ACR_REGISTRY or ACR_NAMESPACE not set."
    exit 1
fi

check_image_source() {
    local image="$1"
    if [[ "$image" == ghcr.io/* ]]; then
        echo "GitHub Container Registry image: ${image}"
    elif [[ "$image" == quay.io/* ]]; then
        echo "Quay.io image: ${image}"
    elif [[ "$image" == */* ]]; then
        echo "Docker Hub image: ${image}"
    else
        echo "Docker Hub official image: ${image}"
    fi
}

process_image_name() {
    local image="$1"
    local processed_image="$image"
    if [[ "$image" == ghcr.io/* ]]; then
        processed_image="${image#ghcr.io/}"
    fi
    if [[ "$image" == quay.io/* ]]; then
        processed_image="${image#quay.io/}"
    fi
    if [[ "$processed_image" == */* ]]; then
        processed_image="${processed_image##*/}"
    fi
    echo "$processed_image"
}

echo "Starting Docker image synchronization to ACR..."
echo "Target Registry: ${ACR_REGISTRY}"
echo "Target Namespace: ${ACR_NAMESPACE}"
echo "-----------------------------------"

while IFS= read -r image; do
    if [[ -z "$image" || "$image" =~ ^# ]]; then
        continue
    fi

    echo "--- Processing image: ${image} ---"
    check_image_source "$image"

    if [[ "$image" == *":"* ]]; then
        original_repo=$(echo "$image" | cut -d ':' -f1)
        original_tag=$(echo "$image" | cut -d ':' -f2)
    else
        original_repo="$image"
        original_tag="latest"
        image="${image}:latest"
    fi

    processed_repo=$(process_image_name "$original_repo")
    target_full_image_path="${ACR_REGISTRY}/${ACR_NAMESPACE}/${processed_repo}:${original_tag}"

    echo "Original: ${image}"
    echo "Target: ${target_full_image_path}"

    if docker manifest inspect "${target_full_image_path}" > /dev/null 2>&1; then
        echo "${target_full_image_path} already exists in ACR, skipping."
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo "-----------------------------------"
        continue
    fi

    echo "Not found in ACR, syncing..."

    if (
        echo "Pulling original image: ${image}..." &&
        retry_command "docker pull \"${image}\"" &&
        echo "Tagging..." &&
        docker tag "${image}" "${target_full_image_path}" &&
        echo "Pushing to ACR..." &&
        retry_command "docker push \"${target_full_image_path}\""
    ); then
        echo "Successfully synced: ${image}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "Failed to sync: ${image}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_IMAGES+=("${image}")
    fi

    docker rmi "${image}" || true
    docker rmi "${target_full_image_path}" || true

    echo "-----------------------------------"
done < "$IMAGES_FILE"

echo "=== SYNC SUMMARY ==="
echo "Success: ${SUCCESS_COUNT}"
echo "Skipped: ${SKIPPED_COUNT}"
echo "Failed: ${FAILED_COUNT}"

if [ ${FAILED_COUNT} -gt 0 ]; then
    echo ""
    echo "Failed images:"
    for failed_image in "${FAILED_IMAGES[@]}"; do
        echo "  - ${failed_image}"
    done
    exit 1
else
    echo "All images processed successfully!"
fi

