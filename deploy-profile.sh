#!/usr/bin/env bash
# Deploy a cloud-init autoinstall profile to the CIDATA partition.
#
# Usage:
#   ./deploy-profile.sh [distro/profile]
#   ./deploy-profile.sh ubuntu/software-engineer --cidata-dir /media/USER/CIDATA

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/autoinstall/templates"
RESOURCES_DIR="${SCRIPT_DIR}/autoinstall/resources"
CIDATA_LABEL="CIDATA"
CIDATA_LINK="/dev/disk/by-label/${CIDATA_LABEL}"

die() { echo "Error: $*" >&2; exit 1; }

list_profiles() {
  find "${TEMPLATES_DIR}" -maxdepth 3 -name "user-data" \
    | sed "s|${TEMPLATES_DIR}/||;s|/user-data||" | sort
}

find_cidata_mount() {
  [[ -L "${CIDATA_LINK}" ]] || return 0
  local real_dev
  real_dev="$(readlink -f "${CIDATA_LINK}")"
  awk -v dev="${real_dev}" '$1 == dev { print $2; exit }' /proc/mounts
}

hash_password() {
  # Read password from stdin to avoid exposing it in argv
  openssl passwd -6 -stdin
}

apply_template() {
  local file="$1" hostname="$2" username="$3" password_hash="$4"
  sed \
    -e "s|{{hostname}}|${hostname}|g" \
    -e "s|{{username}}|${username}|g" \
    -e "s|{{password_hash}}|${password_hash}|g" \
    "${file}"
}

# Build a cloud-init write_files: block from manifest embed directives.
# Replaces the line matching "^# __RESOURCES__$" in the rendered template,
# writing to stdout.
apply_manifest() {
  local rendered="$1" manifest="$2"

  if [[ ! -f "${manifest}" ]]; then
    # No manifest — just remove the sentinel comment
    sed '/^# __RESOURCES__$/,/^# deploy-profile.sh replaces.*/{/^# __RESOURCES__$/d;/^# deploy-profile.sh/d;/^# assembled/d;/^# any user/d}' "${rendered}"
    return
  fi

  local write_files_block=""
  local found_embeds=false

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Strip comments and blank lines
    line="${line%%#*}"
    line="${line#"${line%%[! ]*}"}"  # ltrim
    [[ -z "${line}" ]] && continue

    read -r directive src dest mode owner rest <<< "${line}"
    mode="${mode:-0644}"
    owner="${owner:-root:root}"

    case "${directive}" in
      embed)
        local resource_path="${RESOURCES_DIR}/${src}"
        [[ -f "${resource_path}" ]] \
          || die "Resource not found: ${src} (expected at ${resource_path})"

        local encoded
        encoded="$(base64 -w 76 "${resource_path}")"

        if [[ "${found_embeds}" == false ]]; then
          write_files_block="write_files:"$'\n'
          found_embeds=true
        fi

        write_files_block+="  - path: ${dest}"$'\n'
        write_files_block+="    permissions: '${mode}'"$'\n'
        write_files_block+="    owner: ${owner}"$'\n'
        write_files_block+="    encoding: b64"$'\n'
        write_files_block+="    content: |"$'\n'
        while IFS= read -r chunk; do
          write_files_block+="      ${chunk}"$'\n'
        done <<< "${encoded}"
        ;;
      *)
        die "Unknown manifest directive: ${directive}"
        ;;
    esac
  done < "${manifest}"

  # Replace marker + trailing comment lines with the write_files block (or nothing)
  awk \
    -v block="${write_files_block}" \
    '/^# __RESOURCES__$/ {
      if (block != "") printf "%s", block
      skip = 1
      next
    }
    skip && /^#/ { next }
    { skip = 0; print }' \
    "${rendered}"
}

# ── argument parsing ───────────────────────────────────────────────────────────

PROFILE=""
CIDATA_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cidata-dir) CIDATA_DIR="$2"; shift 2 ;;
    --cidata-dir=*) CIDATA_DIR="${1#*=}"; shift ;;
    -*) die "Unknown option: $1" ;;
    *) PROFILE="$1"; shift ;;
  esac
done

# ── select profile ─────────────────────────────────────────────────────────────

[[ -d "${TEMPLATES_DIR}" ]] \
  || die "Templates directory not found: ${TEMPLATES_DIR}"

mapfile -t PROFILES < <(list_profiles)
[[ ${#PROFILES[@]} -gt 0 ]] || die "No profiles found under ${TEMPLATES_DIR}"

if [[ -z "${PROFILE}" ]]; then
  echo "Available profiles:"
  for i in "${!PROFILES[@]}"; do
    printf "  %d. %s\n" $(( i + 1 )) "${PROFILES[$i]}"
  done
  read -rp "Select profile [1]: " choice
  choice="${choice:-1}"
  PROFILE="${PROFILES[$(( choice - 1 ))]}" \
    || die "Invalid selection"
fi

# Validate
found=false
for p in "${PROFILES[@]}"; do [[ "$p" == "$PROFILE" ]] && found=true && break; done
"${found}" || die "Unknown profile '${PROFILE}'. Available: ${PROFILES[*]}"

PROFILE_DIR="${TEMPLATES_DIR}/${PROFILE}"

# ── prompt for identity fields ─────────────────────────────────────────────────

echo
echo "Configuring profile: ${PROFILE}"

read -rp "Hostname: " HOSTNAME
[[ -n "${HOSTNAME}" ]] || die "Hostname cannot be empty"

read -rp "Username: " USERNAME
[[ -n "${USERNAME}" ]] || die "Username cannot be empty"

read -rsp "Password (will be hashed with SHA-512): " PASSWORD; echo
read -rsp "Confirm password: " PASSWORD2; echo
[[ "${PASSWORD}" == "${PASSWORD2}" ]] || die "Passwords do not match"

printf "Hashing password... "
PASSWORD_HASH="$(printf '%s' "${PASSWORD}" | hash_password)"
echo "done."

# ── locate CIDATA mount ────────────────────────────────────────────────────────

if [[ -z "${CIDATA_DIR}" ]]; then
  CIDATA_DIR="$(find_cidata_mount)"
fi

if [[ -z "${CIDATA_DIR}" || ! -d "${CIDATA_DIR}" ]]; then
  echo "Error: CIDATA partition is not mounted." >&2
  echo "Mount it first or pass --cidata-dir:" >&2
  echo "  sudo mount /dev/disk/by-label/CIDATA /mnt && $0 --cidata-dir /mnt" >&2
  exit 1
fi

# ── render and write seed files ────────────────────────────────────────────────

RENDERED_USERDATA="$(mktemp)"
trap 'rm -f "${RENDERED_USERDATA}"' EXIT

apply_template "${PROFILE_DIR}/user-data" "${HOSTNAME}" "${USERNAME}" "${PASSWORD_HASH}" \
  > "${RENDERED_USERDATA}"

apply_manifest "${RENDERED_USERDATA}" "${PROFILE_DIR}/manifest" \
  > "${CIDATA_DIR}/user-data"

cp "${PROFILE_DIR}/meta-data" "${CIDATA_DIR}/meta-data"

# Write a distro+profile marker so GRUB can show the correct profile name and
# hide entries when CIDATA is prepared for a different distro.
# Timestamp in the file content lets admins see when the profile was deployed.
DISTRO="${PROFILE%%/*}"
PROFILE_SHORT="${PROFILE##*/}"
rm -f "${CIDATA_DIR}"/.distro-*
printf '%s\n' "distro=${DISTRO}" "profile=${PROFILE_SHORT}" "deployed=$(date -Iseconds)" \
  > "${CIDATA_DIR}/.distro-${DISTRO}--${PROFILE_SHORT}"

echo
echo "Profile '${PROFILE}' deployed to ${CIDATA_DIR}"
echo "  hostname : ${HOSTNAME}"
echo "  username : ${USERNAME}"
echo "Ready to boot."
