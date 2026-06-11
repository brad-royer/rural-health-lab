#!/usr/bin/env bash
#
# generate-synthea.sh — Generate a synthetic rural-Texas patient population
# (FHIR R4 transaction bundles) using MITRE Synthea, run inside a temurin
# JDK container. No local Java install required.
#
# Phase 1.4 (issue #7): hub-only population load. See
# docs/runbooks/phase1-synthea.md for the full runbook.
#
# What this does:
#   1. Downloads synthea-with-dependencies.jar (pinned version, see
#      SYNTHEA_VERSION below) into synthea/.cache/ if not already present.
#   2. Runs it via `docker run` against eclipse-temurin:21-jdk (Synthea
#      v4.0.0+ requires JDK 17+; 21 is the current LTS).
#   3. Writes FHIR R4 output to synthea/output/ (gitignored — see
#      docs/runbooks/phase1-synthea.md for why this is not committed).
#
# Reproducibility: fixed seed (-s 1) means re-running this script with the
# same SYNTHEA_VERSION/POPULATION/STATE produces the same population, so the
# generated data does not need to be committed to get it back.
#
# Usage:
#   scripts/generate-synthea.sh
#
# Env overrides (all optional):
#   SYNTHEA_VERSION   - Synthea release tag (default: v4.0.0)
#   POPULATION        - number of patients to generate (default: 100)
#   SEED              - Synthea -s seed value (default: 1)
#   STATE             - state to generate for (default: Texas)
#   JAVA_IMAGE        - container image providing `java` (default:
#                       eclipse-temurin:21-jdk)

set -euo pipefail

# --- Config -----------------------------------------------------------
SYNTHEA_VERSION="${SYNTHEA_VERSION:-v4.0.0}"
POPULATION="${POPULATION:-100}"
SEED="${SEED:-1}"
STATE="${STATE:-Texas}"
JAVA_IMAGE="${JAVA_IMAGE:-eclipse-temurin:21-jdk}"

SYNTHEA_JAR_URL="https://github.com/synthetichealth/synthea/releases/download/${SYNTHEA_VERSION}/synthea-with-dependencies.jar"

# --- Paths --------------------------------------------------------------
# Resolve repo root relative to this script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNTHEA_DIR="${REPO_ROOT}/synthea"
CACHE_DIR="${SYNTHEA_DIR}/.cache"
OUTPUT_DIR="${SYNTHEA_DIR}/output"
JAR_PATH="${CACHE_DIR}/synthea-with-dependencies-${SYNTHEA_VERSION}.jar"

mkdir -p "${CACHE_DIR}" "${OUTPUT_DIR}"

# --- Step 1: download the Synthea jar (cached) ---------------------------
if [ -f "${JAR_PATH}" ]; then
  echo "Synthea jar already cached: ${JAR_PATH}"
else
  echo "Downloading Synthea ${SYNTHEA_VERSION} jar..."
  echo "  ${SYNTHEA_JAR_URL}"
  curl -fL --retry 3 -o "${JAR_PATH}.partial" "${SYNTHEA_JAR_URL}"
  mv "${JAR_PATH}.partial" "${JAR_PATH}"
  echo "Saved to ${JAR_PATH}"
fi

# --- Step 2: run Synthea in a temurin container ---------------------------
#
# Mount:
#   - the cached jar, read-only, at /synthea/synthea-with-dependencies.jar
#   - synthea/output -> /synthea/output (Synthea's default exporter.baseDirectory)
#
# Synthea writes to ./output/<exporter>/... relative to its working
# directory, so we set the container workdir to /synthea and bind-mount
# output/ there.
#
# -p <population> -s <seed> <state>
#   -p: number of patients to attempt to generate (some are discarded for
#       not surviving to a representative age/death — actual count in
#       output may be slightly different from POPULATION)
#   -s: fixed seed for reproducibility
#
# --exporter.fhir.export=true (default true, but explicit) and
# --exporter.hospital.fhir.export / --exporter.practitioner.fhir.export
# ensure the system-level (hospital/practitioner) bundles are written
# alongside per-patient bundles — these are the files load-to-hub.sh loads
# FIRST (see docs/runbooks/phase1-synthea.md for why).
#
# Chronic disease prevalence (diabetes, hypertension) comes from Synthea's
# default Generic Module Framework modules + Texas demographics — no extra
# module config is needed for this increment; -p 100 over a TX age/sex
# distribution should yield a non-trivial number of diabetic/hypertensive
# patients out of the box.

echo ""
echo "Running Synthea: population=${POPULATION} seed=${SEED} state='${STATE}'"
echo "Output -> ${OUTPUT_DIR}"
echo ""

docker run --rm \
  -v "${JAR_PATH}:/synthea/synthea-with-dependencies.jar:ro" \
  -v "${OUTPUT_DIR}:/synthea/output" \
  -w /synthea \
  "${JAVA_IMAGE}" \
  java -jar synthea-with-dependencies.jar \
    -p "${POPULATION}" \
    -s "${SEED}" \
    --exporter.fhir.export=true \
    --exporter.hospital.fhir.export=true \
    --exporter.practitioner.fhir.export=true \
    "${STATE}"

echo ""
echo "Done. FHIR bundles written under ${OUTPUT_DIR}/fhir/"
echo "Next: scripts/load-to-hub.sh"
