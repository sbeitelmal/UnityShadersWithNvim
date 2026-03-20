#!/usr/bin/env bash
# =============================================================================
# setup-shader-lsp.sh — Auto-configure shader-language-server for Unity URP
# =============================================================================
#
# Run this from the root of a Unity project (the directory containing Assets/,
# Library/, Packages/, ProjectSettings/).
#
# It will:
#   1. Detect the Unity Editor version and installation path
#   2. Find URP and render-pipeline packages in Library/PackageCache
#   3. Create .shader-includes/Packages/ symlinks for DXC include resolution
#   4. Generate .shader-language-server.json with all paths and defines
#
# Usage:
#   cd /path/to/your/UnityProject
#   chmod +x setup-shader-lsp.sh
#   ./setup-shader-lsp.sh
#
# Re-running is safe — it will back up and overwrite existing config.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

PROJECT_ROOT="$(pwd)"
CONFIG_FILE="$PROJECT_ROOT/.shader-language-server.json"
SHADER_INCLUDES_DIR="$PROJECT_ROOT/.shader-includes"
UNITY_HUB_EDITORS="$HOME/Unity/Hub/Editor"

# ---- Validate: are we in a Unity project? ----
validate_project() {
    local missing=()
    [ ! -d "Assets" ]           && missing+=("Assets/")
    [ ! -d "ProjectSettings" ]  && missing+=("ProjectSettings/")
    [ ! -d "Library" ]          && missing+=("Library/")
    [ ! -d "Packages" ]         && missing+=("Packages/")

    if [ ${#missing[@]} -gt 0 ]; then
        error "This doesn't look like a Unity project root."
        error "Missing: ${missing[*]}"
        error "Run this script from the root of your Unity project."
        exit 1
    fi

    if [ ! -f "ProjectSettings/ProjectVersion.txt" ]; then
        error "Cannot find ProjectSettings/ProjectVersion.txt"
        error "Has this project been opened in Unity at least once?"
        exit 1
    fi

    if [ ! -d "Library/PackageCache" ]; then
        error "Library/PackageCache does not exist."
        error "Open the project in Unity first so packages are resolved."
        exit 1
    fi
}

# ---- Detect Unity version ----
detect_unity_version() {
    local version_file="ProjectSettings/ProjectVersion.txt"
    UNITY_VERSION=$(grep 'm_EditorVersion:' "$version_file" | head -1 | awk '{print $2}')

    if [ -z "$UNITY_VERSION" ]; then
        error "Could not parse Unity version from $version_file"
        exit 1
    fi

    # Extract the major version number for the UNITY_VERSION define
    # Unity 6000.0.x -> "6000", Unity 2022.3.x -> "2022"
    UNITY_VERSION_MAJOR=$(echo "$UNITY_VERSION" | grep -oP '^\d+')

    info "Unity Editor version: $UNITY_VERSION"
    info "Unity version define: $UNITY_VERSION_MAJOR"
}

# ---- Find Unity Editor installation ----
find_editor_path() {
    EDITOR_PATH="$UNITY_HUB_EDITORS/$UNITY_VERSION"

    if [ ! -d "$EDITOR_PATH" ]; then
        # Try to find any matching version with glob
        local candidates
        candidates=$(find "$UNITY_HUB_EDITORS" -maxdepth 1 -name "${UNITY_VERSION}*" -type d 2>/dev/null | head -1)
        if [ -n "$candidates" ]; then
            EDITOR_PATH="$candidates"
        else
            warn "Unity Editor not found at expected path: $EDITOR_PATH"
            warn "Checking alternative locations..."

            # Check /opt, snap, and other common locations
            for alt in \
                "/opt/Unity/Hub/Editor/$UNITY_VERSION" \
                "/snap/unity-hub/current/Editor/$UNITY_VERSION" \
                "$HOME/.local/share/unity3d/Editor/$UNITY_VERSION" \
                ; do
                if [ -d "$alt" ]; then
                    EDITOR_PATH="$alt"
                    break
                fi
            done
        fi
    fi

    if [ ! -d "$EDITOR_PATH" ]; then
        error "Could not find Unity Editor installation for version $UNITY_VERSION"
        error "Searched: $UNITY_HUB_EDITORS/$UNITY_VERSION"
        error "Set UNITY_HUB_EDITORS env var if your editors are installed elsewhere."
        exit 1
    fi

    # Locate CGIncludes
    CGINCLUDES_PATH="$EDITOR_PATH/Editor/Data/CGIncludes"
    if [ ! -d "$CGINCLUDES_PATH" ]; then
        warn "CGIncludes not found at $CGINCLUDES_PATH"
        warn "Built-in pipeline includes won't work, but URP should be fine."
        CGINCLUDES_PATH=""
    fi

    info "Editor path: $EDITOR_PATH"
    [ -n "$CGINCLUDES_PATH" ] && info "CGIncludes:  $CGINCLUDES_PATH"
}

# ---- Find URP and related packages in PackageCache ----
find_packages() {
    local cache_dir="Library/PackageCache"

    # Package names we care about, in order of importance
    local -a PACKAGE_NAMES=(
        "com.unity.render-pipelines.core"
        "com.unity.render-pipelines.universal"
        "com.unity.render-pipelines.universal-config"
    )

    # Associative arrays for results
    declare -gA PACKAGE_PATHS=()
    declare -gA PACKAGE_DIRS=()

    for pkg_name in "${PACKAGE_NAMES[@]}"; do
        # Find the directory — format is packagename@hash or packagename@version
        local match
        match=$(find "$cache_dir" -maxdepth 1 -name "${pkg_name}@*" -type d 2>/dev/null | head -1)

        if [ -n "$match" ]; then
            local dir_name
            dir_name=$(basename "$match")
            PACKAGE_PATHS["$pkg_name"]="$PROJECT_ROOT/$match"
            PACKAGE_DIRS["$pkg_name"]="$dir_name"
            info "Found package: $dir_name"
        else
            warn "Package not found in cache: $pkg_name"
            if [ "$pkg_name" = "com.unity.render-pipelines.universal" ]; then
                error "This doesn't appear to be a URP project — com.unity.render-pipelines.universal is missing."
                error "If this is a built-in pipeline project, this script is URP-specific."
                exit 1
            fi
        fi
    done
}

# ---- Create .shader-includes symlinks ----
create_symlinks() {
    step "Creating .shader-includes/ symlink directory..."

    # Clean up old symlinks if they exist
    if [ -d "$SHADER_INCLUDES_DIR/Packages" ]; then
        info "Cleaning existing symlinks..."
        rm -rf "$SHADER_INCLUDES_DIR/Packages"
    fi
    mkdir -p "$SHADER_INCLUDES_DIR/Packages"

    local count=0
    for pkg_name in "${!PACKAGE_PATHS[@]}"; do
        local target="${PACKAGE_PATHS[$pkg_name]}"
        local link="$SHADER_INCLUDES_DIR/Packages/$pkg_name"

        ln -sf "$target" "$link"
        info "  Symlink: Packages/$pkg_name -> $(basename "$target")"
        count=$((count + 1))
    done

    # Add .shader-includes to .gitignore if git is in use
    if [ -f "$PROJECT_ROOT/.gitignore" ]; then
        if ! grep -qF '.shader-includes/' "$PROJECT_ROOT/.gitignore"; then
            echo '# Shader LSP include symlinks (generated by setup-shader-lsp.sh)' >> "$PROJECT_ROOT/.gitignore"
            echo '.shader-includes/' >> "$PROJECT_ROOT/.gitignore"
            info "Added .shader-includes/ to .gitignore"
        fi
    fi

    info "Created $count symlinks in .shader-includes/Packages/"
}

# ---- Generate .shader-language-server.json ----
generate_config() {
    step "Generating $CONFIG_FILE..."

    # Back up existing config
    if [ -f "$CONFIG_FILE" ]; then
        local backup="${CONFIG_FILE}.bak"
        cp "$CONFIG_FILE" "$backup"
        warn "Backed up existing config to $(basename "$backup")"
    fi

    # Build includes array
    local includes=""

    # CGIncludes (built-in pipeline headers)
    if [ -n "$CGINCLUDES_PATH" ]; then
        includes+="        \"$CGINCLUDES_PATH\","$'\n'
    fi

    # .shader-includes for DXC virtual path resolution (Packages/... symlinks)
    includes+="        \"$SHADER_INCLUDES_DIR\","$'\n'

    # Package-specific include directories
    # These are the directories DXC/glslang search when resolving #include "SomeFile.hlsl"
    for pkg_name in \
        "com.unity.render-pipelines.core" \
        "com.unity.render-pipelines.universal" \
        ; do
        local base="${PACKAGE_PATHS[$pkg_name]:-}"
        if [ -n "$base" ]; then
            [ -d "$base/ShaderLibrary" ] && includes+="        \"$base/ShaderLibrary\","$'\n'
            [ -d "$base/Shaders" ]       && includes+="        \"$base/Shaders\","$'\n'
            [ -d "$base/Runtime" ]        && includes+="        \"$base/Runtime\","$'\n'
        fi
    done

    # Runtime config for universal-config
    local config_pkg="${PACKAGE_PATHS[com.unity.render-pipelines.universal-config]:-}"
    if [ -n "$config_pkg" ] && [ -d "$config_pkg/Runtime" ]; then
        includes+="        \"$config_pkg/Runtime\","$'\n'
    fi

    # Remove trailing comma from the last entry
    includes=$(printf '%s' "$includes" | sed '$ s/,$//')

    # Build pathRemapping
    local remapping=""
    for pkg_name in "${!PACKAGE_PATHS[@]}"; do
        remapping+="        \"Packages/$pkg_name\": \"${PACKAGE_PATHS[$pkg_name]}\","$'\n'
    done
    remapping=$(printf '%s' "$remapping" | sed '$ s/,$//')

    # Write the config
    cat > "$CONFIG_FILE" << JSONEOF
{
    "includes": [
$includes
    ],
    "defines": {
        "UNITY_VERSION": "$UNITY_VERSION_MAJOR",
        "SHADER_TARGET": "50",
        "SHADER_API_D3D11": "1"
    },
    "pathRemapping": {
$remapping
    },
    "hlsl": {
    }
}
JSONEOF

    info "Config written to $CONFIG_FILE"
}

# ---- Add .shader-language-server.json to .gitignore ----
update_gitignore() {
    if [ -f "$PROJECT_ROOT/.gitignore" ]; then
        if ! grep -qF '.shader-language-server.json' "$PROJECT_ROOT/.gitignore"; then
            echo '# Shader language server config (generated by setup-shader-lsp.sh)' >> "$PROJECT_ROOT/.gitignore"
            echo '.shader-language-server.json' >> "$PROJECT_ROOT/.gitignore"
            info "Added .shader-language-server.json to .gitignore"
        fi
    fi
}

# ---- Summary ----
print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Setup complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "  Project:      $PROJECT_ROOT"
    echo "  Unity:        $UNITY_VERSION"
    echo "  Config:       $CONFIG_FILE"
    echo "  Symlinks:     $SHADER_INCLUDES_DIR/Packages/"
    echo ""
    echo "  What's configured:"
    echo "    - DXC validation with SM 6.8 (default)"
    echo "    - SHADER_API_D3D11 for Unity shader API checks"
    echo "    - URP include paths and Packages/ symlinks for DXC resolution"
    echo "    - CGIncludes for built-in pipeline headers"
    echo "    - pathRemapping for tree-sitter symbol resolution"
    echo ""
    echo "  To use:"
    echo "    1. Open any .compute, .hlsl, or .cginc file in nvim"
    echo "    2. shader-language-server should pick up the config automatically"
    echo "    3. Check :lua vim.print(vim.diagnostic.get(0)) for diagnostics"
    echo ""
    echo "  Notes:"
    echo "    - Built-in pipeline files (UnityCG.cginc) will show false positives"
    echo "      under DXC — this is expected (legacy Cg types)."
    echo "    - If you update Unity or URP version, re-run this script."
    echo "    - The .shader-includes/ dir and config are gitignored."
    echo ""
}

# ---- Main ----
main() {
    echo ""
    echo -e "${CYAN}setup-shader-lsp.sh — Unity URP Shader LSP Setup${NC}"
    echo ""

    validate_project
    detect_unity_version
    find_editor_path
    find_packages
    create_symlinks
    generate_config
    update_gitignore
    print_summary
}

main "$@"
