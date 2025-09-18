#!/usr/bin/env zsh
# Sanity test for Star Wars demo + Tetragon policies
# Alternates between request-landing (Xwing/Tiefighter) and SSH attempts

NS="tetragon-demo"
XWING="xwing"
TIE="tiefighter"
DEATHSTAR="deathstar.${NS}.svc.cluster.local"

echo "🚀 Starting sanity test (namespace=$NS)..."
echo "Press Ctrl+C to stop."
echo

i=1
while true; do
  echo "=== Round $i ==="

  # Random delay before X-Wing request (1-3 seconds)
  sleep $(( RANDOM % 3 + 1 ))
  echo "🛸 X-Wing: request landing..."
  oc exec -n "$NS" "$XWING" -- \
    curl -s -X POST "http://${DEATHSTAR}/v1/request-landing" || true

  # Random delay before TIE Fighter request (2-5 seconds)  
  sleep $(( RANDOM % 3 + 2 ))
  echo "⚔️  TIE Fighter: request landing..."
  oc exec -n "$NS" "$TIE" -- \
    curl -s -X POST "http://${DEATHSTAR}/v1/request-landing" || true

  # Random delay before X-Wing SSH attempts (1-2 seconds)
  sleep $(( RANDOM % 2 + 1 ))
  echo "🚫 X-Wing: parallel SSH attempts to Death Star (should be blocked)..."
  
  # Launch 4 parallel SSH attempts from X-Wing
  for j in {1..4}; do
    (
      echo "  X-Wing SSH attempt $j starting..."
      oc exec -n "$NS" "$XWING" -- \
        curl -v --connect-timeout 2 "http://${DEATHSTAR}:22" 2>&1 | \
        sed "s/^/  [X-$j] /" || true
    ) &
  done
  
  # Wait for X-Wing SSH attempts to complete
  wait
  echo "  All X-Wing SSH attempts completed."

  # Random delay before TIE Fighter SSH attempts (1-2 seconds)
  sleep $(( RANDOM % 2 + 1 ))
  echo "🚫 TIE Fighter: parallel SSH attempts to Death Star (should be blocked)..."
  
  # Launch 4 parallel SSH attempts from TIE Fighter
  for j in {1..4}; do
    (
      echo "  TIE Fighter SSH attempt $j starting..."
      oc exec -n "$NS" "$TIE" -- \
        curl -v --connect-timeout 2 "http://${DEATHSTAR}:22" 2>&1 | \
        sed "s/^/  [T-$j] /" || true
    ) &
  done
  
  # Wait for TIE Fighter SSH attempts to complete
  wait
  echo "  All TIE Fighter SSH attempts completed."

  echo
  # Random delay before next round (3-7 seconds)
  sleep $(( RANDOM % 5 + 3 ))
  i=$((i+1))
done