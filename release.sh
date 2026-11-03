#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Jia Liu

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== tokl Release Script ===${NC}\n"

# Check if we're on main branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo -e "${RED}Error: Not on main branch. Current branch: $CURRENT_BRANCH${NC}"
    exit 1
fi
echo -e "${GREEN}✓ On main branch${NC}"

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo -e "${RED}Error: There are uncommitted changes:${NC}"
    git status --short
    exit 1
fi
echo -e "${GREEN}✓ No uncommitted changes${NC}"

# Check for untracked files
UNTRACKED=$(git ls-files --others --exclude-standard)
if [ -n "$UNTRACKED" ]; then
    echo -e "${YELLOW}Warning: There are untracked files:${NC}"
    echo "$UNTRACKED"
    echo -e "${YELLOW}These files will NOT be included in the release.${NC}"
fi

# Fetch and check sync with remote
echo -e "\n${GREEN}Fetching from remote...${NC}"
git fetch origin

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" != "$REMOTE" ]; then
    AHEAD=$(git rev-list --count origin/main..HEAD)
    BEHIND=$(git rev-list --count HEAD..origin/main)

    if [ "$AHEAD" -gt 0 ]; then
        echo -e "${YELLOW}Local is $AHEAD commits ahead of origin/main${NC}"
    fi
    if [ "$BEHIND" -gt 0 ]; then
        echo -e "${RED}Error: Local is $BEHIND commits behind origin/main. Pull first.${NC}"
        exit 1
    fi
    if [ "$AHEAD" -gt 0 ]; then
        echo -e "${YELLOW}Need to push $AHEAD commits first.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓ In sync with origin/main${NC}"

# Get latest tag
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.1.3")
echo -e "\n${GREEN}Latest tag: ${LATEST_TAG}${NC}"

# Parse version number
VERSION=${LATEST_TAG#v}
MAJOR=$(echo $VERSION | cut -d. -f1)
MINOR=$(echo $VERSION | cut -d. -f2)
PATCH=$(echo $VERSION | cut -d. -f3)

# Increment patch version
NEW_PATCH=$((PATCH + 1))
NEW_TAG="v${MAJOR}.${MINOR}.${NEW_PATCH}"
NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"

echo -e "${GREEN}New tag: ${NEW_TAG}${NC}"

# Find Cargo.toml
CARGO_TOML="Cargo.toml"
if [ ! -f "$CARGO_TOML" ]; then
    echo -e "${RED}Error: Cargo.toml not found${NC}"
    exit 1
fi
echo -e "${GREEN}Found Cargo.toml${NC}"

# Get current version from Cargo.toml
CURRENT_VERSION=$(grep '^version = ' Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')
echo -e "\n${GREEN}Current Cargo.toml version: ${CURRENT_VERSION}${NC}"

# Summary
echo -e "\n${YELLOW}=== Summary ===${NC}"
echo -e "Tag:        ${LATEST_TAG} → ${GREEN}${NEW_TAG}${NC}"
echo -e "Cargo.toml: ${CURRENT_VERSION} → ${GREEN}${NEW_VERSION}${NC}"

# Ask for confirmation
echo -e "\n${YELLOW}Proceed with commit and push? [y/N]${NC}"
read -r CONFIRM

# Only proceed if user explicitly types 'y' or 'Y'
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 0
fi

echo -e "\n${GREEN}Updating Cargo.toml...${NC}"
sed -i '' "s/^version = \".*\"/version = \"${NEW_VERSION}\"/" Cargo.toml

echo -e "${GREEN}Committing changes...${NC}"
git add Cargo.toml Cargo.lock
git commit -m "Bump version to ${NEW_VERSION}" -s

echo -e "${GREEN}Creating tag ${NEW_TAG}...${NC}"
git tag -a "$NEW_TAG" -m "Release $NEW_TAG"

echo -e "${GREEN}Pushing to origin...${NC}"
git push origin main
git push origin "$NEW_TAG"

echo -e "\n${GREEN}=== Release $NEW_TAG completed! ===${NC}"
