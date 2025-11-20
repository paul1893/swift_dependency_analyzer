#!/bin/bash
# swift_dependency_analyzer.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 <path_to_swift_project> [options]"
    echo ""
    echo "Arguments:"
    echo "  path_to_swift_project  - Root directory containing Swift files"
    echo ""
    echo "Options:"
    echo "  -o, --output <file>                       - Output DOT file (default: dependencies.dot)"
    echo "  -e, --exclude <regex>                     - Exclude path or modules matching pattern (can be used multiple times). Support regex."
    echo "                                              Example: *Tests, Test*, *Mock*"
    echo "  --include-system                          - Include system frameworks in the graph (default: off)"
    echo "  --trim-prefix <regex>                     - Extract root module name using regex (use parenthesis to capture)"
    echo "                                              Can be specified multiple times. First matching pattern is used."
    echo "                                              Example: '^Targets/([^/]+)/' or '^Toolkit/Sources/([^/]+)/'"
    echo ""
    echo "Examples:"
    echo "  $0 ./project"
    echo "  $0 ./project -o custom_deps.dot"
    echo "  $0 ./project --exclude '*Tests'"
    echo "  $0 ./project --exclude '*Tests' --exclude '*Mocks' -o deps.dot --include-system"
    echo "  $0 ./project --trim-prefix '^Targets/([^/]+)/' --trim-prefix '^Toolkit/Sources/([^/]+)/'"
    exit 1
}

# Check arguments
if [ $# -lt 1 ]; then
    usage
fi

INPUT_PATH="$1"
shift

TRIM_PREFIX_REGEXES=()
INCLUDE_SYSTEM_FRAMEWORKS=false
OUTPUT_FILE="dependencies.dot"
EXCLUDE_PATTERNS=()

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: --output requires an argument${NC}"
                exit 1
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -e|--exclude)
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: --exclude requires an argument${NC}"
                exit 1
            fi
            EXCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        --include-system)
            INCLUDE_SYSTEM_FRAMEWORKS=true
            shift
            ;;
        --trim-prefix)
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: --trim-prefix requires a regex pattern as argument${NC}"
                exit 1
            fi
            TRIM_PREFIX_REGEXES+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validate input path
if [ ! -d "$INPUT_PATH" ]; then
    echo -e "${RED}Error: Directory '$INPUT_PATH' does not exist${NC}"
    exit 1
fi

# Get absolute path and folder name
ROOT_PATH=$(cd "$INPUT_PATH" && pwd)
ROOT_FOLDER=$(basename "$ROOT_PATH")

echo -e "${BLUE}🔍 Analyzing Swift dependencies in: ${ROOT_PATH}${NC}"
echo -e "${BLUE}📦 Root module: ${ROOT_FOLDER}${NC}"

if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
    echo -e "${BLUE}🚫 Excluding patterns:${NC}"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        echo -e "${BLUE}   - ${pattern}${NC}"
    done
fi

if [ ${#TRIM_PREFIX_REGEXES[@]} -gt 0 ]; then
    echo -e "${BLUE}📑 Using root regexes:${NC}"
    for r in "${TRIM_PREFIX_REGEXES[@]}"; do
        echo -e "${BLUE}   - $r${NC}"
    done
fi

# Use temporary files instead of associative arrays
TEMP_DIR=$(mktemp -d)
DEPENDENCIES_FILE="$TEMP_DIR/dependencies.txt"
MODULE_COUNTS_FILE="$TEMP_DIR/module_counts.txt"
PROCESSED_FILES_FILE="$TEMP_DIR/processed_files.txt"
EXCLUDED_MODULES_FILE="$TEMP_DIR/excluded_modules.txt"
PROJECT_MODULES_FILE="$TEMP_DIR/project_modules.txt"

touch "$DEPENDENCIES_FILE"
touch "$MODULE_COUNTS_FILE"
touch "$PROCESSED_FILES_FILE"
touch "$EXCLUDED_MODULES_FILE"
touch "$PROJECT_MODULES_FILE"

# Cleanup on exit
trap "rm -rf $TEMP_DIR" EXIT

# Statistics
TOTAL_FILES=0
TOTAL_IMPORTS=0
EXCLUDED_COUNT=0

# Function to sanitize module names for DOT format
sanitize_name() {
    local name="$1"
    # Replace special characters with underscores
    echo "$name" | sed 's/[^a-zA-Z0-9_]/_/g'
}

# Function to determine if an import is a system framework
is_system_framework() {
    local module="$1"
    # Common system frameworks
    case "$module" in
        Foundation|UIKit|SwiftUI|Combine|CoreData|CoreGraphics|CoreLocation|MapKit|AVFoundation|\
        UserNotifications|WebKit|SafariServices|StoreKit|CloudKit|HealthKit|HomeKit|PassKit|\
        SpriteKit|SceneKit|ARKit|RealityKit|QuartzCore|Metal|MetalKit|Vision|CoreML|CreateML|\
        NaturalLanguage|Speech|Intents|IntentsUI|WidgetKit|AppKit|Cocoa|Darwin|Dispatch|\
        ObjectiveC|os|XCTest|SwiftData|Observation|OSLog|Network|CryptoKit|AuthenticationServices|\
        LocalAuthentication|CoreBluetooth|CoreMotion|EventKit|EventKitUI|MessageUI|Photos|\
        PhotosUI|AVKit|MediaPlayer|GameKit|GameController|ReplayKit|CoreImage|ImageIO|\
        CoreText|CoreAnimation|GLKit|ModelIO|CoreHaptics|CoreNFC|CoreSpotlight|CoreTelephony|\
        CarPlay|CallKit|Contacts|ContactsUI|Social|Accounts|AdSupport|iAd|JavaScriptCore|\
        PDFKit|PencilKit|LinkPresentation|BackgroundTasks|Accelerate|simd|CoreVideo|CoreMedia|\
        CoreAudio|CoreAudioKit|CoreMIDI|AudioToolbox|AVFAudio|SoundAnalysis|VisionKit|\
        DeviceCheck|AppTrackingTransparency|UniformTypeIdentifiers|GroupActivities|ShazamKit|\
        ScreenTime|FamilyControls|ManagedSettings|SensorKit|ProximityReader|ActivityKit|\
        WeatherKit|Charts|MapKit|QuickLook|QuickLookUI|SafariUI|ThreadNetwork|PackageDescription|\
        Testing|OrderedCollections|Concurrency|WatchConnectivity|MobileCoreServices|Foundation.NSDate|\
        CoreLocation.CLLocation|UIKit.UIDevice|Foundation.NSData|CoreLocation.CLLocationCoordinate2D|\
        UIKit.UIImage|Foundation.NSURL|UIKit.UIColor)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if file was processed
is_processed() {
    local file="$1"
    grep -Fxq "$file" "$PROCESSED_FILES_FILE" 2>/dev/null
}

# Function to mark file as processed
mark_processed() {
    local file="$1"
    echo "$file" >> "$PROCESSED_FILES_FILE"
}

# Function to add dependency (from_module, to_module)
add_dependency() {
    local from_module="$1"
    local to_module="$2"
    local dep_key="${from_module}|${to_module}"

    if ! grep -Fxq "$dep_key" "$DEPENDENCIES_FILE" 2>/dev/null; then
        echo "$dep_key" >> "$DEPENDENCIES_FILE"
    fi
}

# Function to increment module count (for imported module)
increment_module_count() {
    local module="$1"
    local count=1

    # Check if module exists in counts
    if grep -q "^${module}|" "$MODULE_COUNTS_FILE" 2>/dev/null; then
        count=$(grep "^${module}|" "$MODULE_COUNTS_FILE" | cut -d'|' -f2)
        count=$((count + 1))
        # Remove old entry
        grep -v "^${module}|" "$MODULE_COUNTS_FILE" > "$MODULE_COUNTS_FILE.tmp" || touch "$MODULE_COUNTS_FILE.tmp"
        mv "$MODULE_COUNTS_FILE.tmp" "$MODULE_COUNTS_FILE"
    fi

    echo "${module}|${count}" >> "$MODULE_COUNTS_FILE"
}

# Function to check if file path matches any exclude pattern
is_file_excluded() {
    local file="$1"
    local relative_path="${file#$ROOT_PATH/}"
    if [[ -z "${EXCLUDE_PATTERNS+x}" ]]; then
        return 1
    fi
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$relative_path" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Function to check if module name matches any exclude pattern
is_module_excluded() {
    local module="$1"
    if [[ -z "${EXCLUDE_PATTERNS+x}" ]]; then
        return 1
    fi
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$module" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Given a filepath, determine the module name via TRIM_PREFIX_REGEXES
file_to_module() {
    local relative="$1"
    if [[ -z "${TRIM_PREFIX_REGEXES+x}" ]]; then
        local root="${relative%%/*}"
        echo "$root"
        return
    fi
    for regex in "${TRIM_PREFIX_REGEXES[@]}"; do
        if [[ "$relative" =~ $regex ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
    done
    # Fallback: use the root of $relative (first path component)
    local root="${relative%%/*}"
    echo "$root"
}

# Check if a module is in the project modules list
is_project_module() {
    local module="$1"
    grep -Fxq "$module" "$PROJECT_MODULES_FILE" 2>/dev/null
}

# Normalize module name - if it's a project module, return it, otherwise return as-is
normalize_module_name() {
    local module="$1"
    
    # If it's a system framework, return as-is
    if is_system_framework "$module"; then
        echo "$module"
        return
    fi
    
    # If it's in our project modules list, return it
    if is_project_module "$module"; then
        echo "$module"
        return
    fi
    
    # Otherwise return as-is
    echo "$module"
}

# Step 1: Build list of project modules from directory structure
echo -e "${GREEN}📂 Discovering project modules...${NC}"

if [ ${#TRIM_PREFIX_REGEXES[@]} -gt 0 ]; then
    find "$ROOT_PATH" -type f -name "*.swift" | while read -r file; do
        rel="${file#$ROOT_PATH/}"
        for regex in "${TRIM_PREFIX_REGEXES[@]}"; do
            if [[ "$rel" =~ $regex ]]; then
                mod="${BASH_REMATCH[1]}"
                echo "$mod" >> "$PROJECT_MODULES_FILE"
                break
            fi
        done
    done
    
    # Sort and deduplicate
    sort -u "$PROJECT_MODULES_FILE" -o "$PROJECT_MODULES_FILE"
    
    if [ -s "$PROJECT_MODULES_FILE" ]; then
        MODULE_COUNT=$(wc -l < "$PROJECT_MODULES_FILE" | tr -d ' ')
        echo -e "${GREEN}   Found ${MODULE_COUNT} project modules${NC}"
    fi
fi

# Step 2: Process files
process_file() {
    local file="$1"
    local relative_path="${file#$ROOT_PATH/}"

    if is_file_excluded "$file"; then
        echo -e "${RED}  Skipping (excluded): ${relative_path}${NC}"
        return
    fi
    
    if is_processed "$file"; then
        return
    fi

    mark_processed "$file"
    TOTAL_FILES=$((TOTAL_FILES + 1))
    echo -e "${YELLOW}  Processing: ${relative_path}${NC}"

    # Determine the module the file belongs to
    local from_module
    from_module="$(file_to_module "$relative_path")"
    echo -e "   ${BLUE}  Module: ${from_module}${NC}"

    # Parse import lines until the first non-import, non-empty, non-comment
    local -a imports=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading and trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Skip single-line comments
        [[ "$line" =~ ^// ]] && continue
        
        # Skip multi-line comment starts (simplified)
        [[ "$line" =~ ^/\* ]] && continue
        [[ "$line" =~ ^\* ]] && continue

        # Check if it's an import statement
        # Match lines with optional attributes and ACLs
        if echo "$line" | grep -qE '^[[:space:]]*(@[a-zA-Z0-9_]+[[:space:]]+)*((public|internal|private|fileprivate|open|package)[[:space:]]+)?import[[:space:]]+(struct[[:space:]]+)?[a-zA-Z0-9_.]+'; then
            # Extract the module name using awk for clarity & POSIX portability
            module=$(echo "$line" | awk '
            {
                for (i = 1; i <= NF; i++)
                    if ($i == "import") {
                        if ($(i+1) ~ /^(struct|class|enum|protocol)$/)
                            print $(i+2)
                        else
                            print $(i+1)
                        break
                    }
            }')
            if [ -n "$module" ] && [ "$module" != "import" ]; then
                imports+=("$module")
            fi
        else
            break
        fi
    done < "$file"

    # Process each import - check if array has elements first
    if [ ${#imports[@]} -gt 0 ]; then
        for module in "${imports[@]}"; do
            # Skip excluded modules
            if is_module_excluded "$module"; then
                echo "$module" >> "$EXCLUDED_MODULES_FILE"
                continue
            fi
            
            # Skip system frameworks if not included
            if is_system_framework "$module" && [ "$INCLUDE_SYSTEM_FRAMEWORKS" = false ]; then
                continue
            fi

            # Normalize module name
            local target_mod
            target_mod="$(normalize_module_name "$module")"
            
            # Don't self-link
            [ "$from_module" == "$target_mod" ] && continue

            TOTAL_IMPORTS=$((TOTAL_IMPORTS+1))
            add_dependency "$from_module" "$target_mod"
            increment_module_count "$target_mod"
        done
    fi
}

# Main processing loop
echo -e "${GREEN}📂 Scanning for Swift files...${NC}"

# Find all Swift files and process them
while read -r file; do
    process_file "$file"
done <<< "$(find "$ROOT_PATH" -name "*.swift" -type f)"

echo -e "${GREEN}✅ Processed ${TOTAL_FILES} Swift files${NC}"
echo -e "${GREEN}📊 Found ${TOTAL_IMPORTS} total import statements${NC}"

if [ -s "$EXCLUDED_MODULES_FILE" ]; then
    EXCLUDED_COUNT=$(sort -u "$EXCLUDED_MODULES_FILE" | wc -l | tr -d ' ')
    echo -e "${YELLOW}🚫 Excluded ${EXCLUDED_COUNT} unique modules${NC}"
fi

# Generate DOT file
echo -e "${BLUE}📝 Generating DOT graph: ${OUTPUT_FILE}${NC}"

cat > "$OUTPUT_FILE" << 'DOT_HEADER'
digraph SwiftDependencies {
    // Graph attributes
    rankdir=LR;
    node [shape=box, style=rounded, fontname="Helvetica"];
    edge [fontname="Helvetica", fontsize=10];

    // Define node styles
    node [fillcolor=lightblue, style="rounded,filled"];

DOT_HEADER

# Add all unique source "from" modules with special styling
FROM_MODULES=$(cut -d'|' -f1 "$DEPENDENCIES_FILE" | sort -u)
for mod in $FROM_MODULES; do
    sanitized=$(sanitize_name "$mod")
    echo "    \"$sanitized\" [label=\"$mod\", fillcolor=gold, shape=box, style=\"rounded,filled,bold\"];" >> "$OUTPUT_FILE"
done
echo "" >> "$OUTPUT_FILE"

# Get unique modules and separate system/custom
SYSTEM_MODULES_FILE="$TEMP_DIR/system_modules.txt"
CUSTOM_MODULES_FILE="$TEMP_DIR/custom_modules.txt"
touch "$SYSTEM_MODULES_FILE"
touch "$CUSTOM_MODULES_FILE"

sort -u "$MODULE_COUNTS_FILE" | while IFS='|' read -r module count; do
    if is_system_framework "$module"; then
        echo "${module}|${count}" >> "$SYSTEM_MODULES_FILE"
    else
        echo "${module}|${count}" >> "$CUSTOM_MODULES_FILE"
    fi
done

write_system_modules() {
    if [ "$INCLUDE_SYSTEM_FRAMEWORKS" = true ] && [ -s "$SYSTEM_MODULES_FILE" ]; then
        echo "    // System Frameworks"
        while IFS='|' read -r module count; do
            sanitized=$(sanitize_name "$module")
            echo "    \"$sanitized\" [label=\"$module\n($count refs)\", fillcolor=lightgray, shape=component];"
        done < "$SYSTEM_MODULES_FILE"
    fi
}

write_custom_modules() {
    if [ -s "$CUSTOM_MODULES_FILE" ]; then
        echo ""
        echo "    // Custom Modules"
        while IFS='|' read -r module count; do
            sanitized=$(sanitize_name "$module")
            echo "    \"$sanitized\" [label=\"$module\n($count refs)\", fillcolor=lightgreen];"
        done < "$CUSTOM_MODULES_FILE"
    fi
}

write_dependencies() {
    echo ""
    echo "    // Dependencies"
    sort -u "$DEPENDENCIES_FILE" | while IFS='|' read -r from to; do
        from_sanitized=$(sanitize_name "$from")
        to_sanitized=$(sanitize_name "$to")
        # Suppress catch-all root edges as "from"
        # if [ "$from" == "$ROOT_FOLDER" ] || [ -z "$from" ]; then
        #     continue  # skip if from is generic/root
        # fi
        # Suppress self-links
        if [ "$from" == "$to" ]; then
            continue
        fi
        echo "    \"$from_sanitized\" -> \"$to_sanitized\";"
    done
}

write_system_modules >> "$OUTPUT_FILE"
write_custom_modules >> "$OUTPUT_FILE"
write_dependencies >> "$OUTPUT_FILE"

# Close the graph
echo "}" >> "$OUTPUT_FILE"

echo -e "${GREEN}✅ DOT file generated: ${OUTPUT_FILE}${NC}"

# Display statistics
UNIQUE_MODULES=$(cut -d'|' -f1 "$MODULE_COUNTS_FILE" | sort -u | wc -l | tr -d ' ')
SYSTEM_COUNT=$(wc -l < "$SYSTEM_MODULES_FILE" | tr -d ' ')
CUSTOM_COUNT=$(wc -l < "$CUSTOM_MODULES_FILE" | tr -d ' ')

echo ""
echo -e "${BLUE}📊 Dependency Statistics:${NC}"
echo -e "${BLUE}========================${NC}"
echo -e "Total Swift files: ${TOTAL_FILES}"
echo -e "Total imports: ${TOTAL_IMPORTS}"
echo -e "Unique modules: ${UNIQUE_MODULES}"
echo -e "  - System frameworks: ${SYSTEM_COUNT}"
echo -e "  - Custom modules: ${CUSTOM_COUNT}"

if [ -s "$EXCLUDED_MODULES_FILE" ]; then
    EXCLUDED_COUNT=$(wc -l < "$EXCLUDED_MODULES_FILE" | tr -d ' ')
    echo -e "  - Excluded modules: ${EXCLUDED_COUNT}"
fi

echo ""

# Show top dependencies
echo -e "${BLUE}Top 10 Dependencies:${NC}"
sort -t'|' -k2 -nr "$MODULE_COUNTS_FILE" | head -10 | while IFS='|' read -r module count; do
    echo -e "  ${count}x - ${module}"
done

# Try to generate visualization if graphviz is available
echo ""
if command -v dot &> /dev/null; then
    echo -e "${GREEN}🎨 Graphviz detected! Generating visualizations...${NC}"

    base_name="${OUTPUT_FILE%.dot}"

    # Generate SVG
    if dot -Tsvg "$OUTPUT_FILE" -o "${base_name}.svg" 2>/dev/null; then
        echo -e "${GREEN}✅ Generated: ${base_name}.svg${NC}"
    fi

    # Generate PNG
    if dot -Tpng -Gdpi=300 "$OUTPUT_FILE" -o "${base_name}.png" 2>/dev/null; then
        echo -e "${GREEN}✅ Generated: ${base_name}.png${NC}"
    fi

    # Generate PDF
    if dot -Tpdf "$OUTPUT_FILE" -o "${base_name}.pdf" 2>/dev/null; then
        echo -e "${GREEN}✅ Generated: ${base_name}.pdf${NC}"
    fi

    # Try to open the SVG file
    if [ -f "${base_name}.svg" ]; then
        echo ""
        echo -e "${YELLOW}Opening visualization...${NC}"
        open "${base_name}.svg"
    fi
else
    echo -e "${YELLOW}⚠️  Graphviz not found. Install it to generate visualizations:${NC}"
    echo -e "${YELLOW}   brew install graphviz${NC}"
    echo ""
    echo -e "${YELLOW}To manually generate visualization:${NC}"
    echo -e "${YELLOW}   dot -Tsvg ${OUTPUT_FILE} -o ${OUTPUT_FILE%.dot}.svg${NC}"
    echo -e "${YELLOW}   dot -Tpng ${OUTPUT_FILE} -o ${OUTPUT_FILE%.dot}.png${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Analysis complete!${NC}"