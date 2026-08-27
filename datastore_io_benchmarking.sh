#!/usr/bin/env bash
set -euo pipefail

# VM Datastore Concurrency Benchmark - production-safe profile
#
# Goal: characterize 1,5,10,15,20,25,30,35 concurrent VM-like I/O streams
# without creating an unbounded I/O queue or continuing for hours after abort.
#
# Run INSIDE a disposable Linux benchmark VM, against a dedicated secondary
# filesystem whose virtual disk lives on the datastore being tested.
# Run ONE datastore at a time.
#
# Usage:
#   sudo ./vm_datastore_sweep_prod_safe.sh TESTDIR LABEL [GiB_per_VM]
#
# Example:
#   sudo ./vm_datastore_sweep_prod_safe.sh /mnt/iscsi3-test iscsi3 2
#
# Defaults / safety design:
#   - 2 GiB per simulated VM (70 GiB max working set at 35 streams)
#   - queue depth 1 for boot, 2 for interactive/install
#   - max 70 outstanding random I/Os at 35 streams
#   - each measured step is time-bounded (20 s + 5 s ramp)
#   - fio aborts a workload if any I/O exceeds 2 seconds
#   - script stops higher concurrency for a profile when p95 >= 250 ms
#   - GNU timeout provides an outer wall-clock kill guard
#   - Ctrl-C / SIGTERM exits immediately; no sync or cleanup is forced on abort
#   - benchmark files are NOT auto-deleted at the end
#
# This measures the deployed path, INCLUDING TrueNAS ARC. It is intentionally
# not a "defeat all caches at any cost" benchmark. For today's production
# capacity question, that is desirable because ARC is part of real behavior.

TESTDIR="${1:-}"
LABEL="${2:-}"
FILE_SIZE_GIB="${3:-2}"

if [[ -z "$TESTDIR" || -z "$LABEL" ]]; then
  echo "Usage: sudo $0 TESTDIR LABEL [GiB_per_VM]" >&2
  exit 2
fi
if ! [[ "$FILE_SIZE_GIB" =~ ^[1-9][0-9]*$ ]]; then
  echo "GiB_per_VM must be a positive integer." >&2
  exit 2
fi

for cmd in fio python3 df findmnt lsblk awk sed hostname timeout readlink; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

REAL_TESTDIR="$(readlink -f "$TESTDIR")"
if [[ ! -d "$REAL_TESTDIR" ]]; then
  echo "Test directory does not exist: $REAL_TESTDIR" >&2
  exit 1
fi
case "$REAL_TESTDIR" in
  /|/boot|/boot/*|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/home|/home/*)
    echo "Refusing dangerous test path: $REAL_TESTDIR" >&2
    echo "Use a dedicated mounted benchmark filesystem." >&2
    exit 1
    ;;
esac

SAFE_LABEL="$(printf '%s' "$LABEL" | sed 's/[^A-Za-z0-9_.-]/_/g')"
JOBS=(1 5 10 15 20 25 30 35)
MAX_JOBS=35
RUNTIME=20
RAMP=5
PAUSE=5
MAX_IO_LATENCY="2s"
STOP_P95_MS="${STOP_P95_MS:-250}"
PREP_TIMEOUT="${PREP_TIMEOUT:-30m}"
STEP_TIMEOUT=$((RUNTIME + RAMP + 20))
PROFILES=(boot interactive install)

RUN_ID="${SAFE_LABEL}-$(date +%Y%m%d-%H%M%S)"
OUTDIR="${PWD}/fio-results-${RUN_ID}"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.csv"
REPORT="$OUTDIR/report.txt"
MASTER_CSV="${PWD}/vm-datastore-master.csv"
FILE_PREFIX="$REAL_TESTDIR/.vmbench-${SAFE_LABEL}"
REQUIRED_GIB=$((MAX_JOBS * FILE_SIZE_GIB))
FREE_KIB=$(df -Pk "$REAL_TESTDIR" | awk 'NR==2 {print $4}')
FREE_GIB=$((FREE_KIB / 1024 / 1024))
MIN_FREE_GIB=$((REQUIRED_GIB + REQUIRED_GIB / 10 + 2))

if (( FREE_GIB < MIN_FREE_GIB )); then
  echo "Not enough free space." >&2
  echo "Need about ${MIN_FREE_GIB} GiB; available ${FREE_GIB} GiB." >&2
  exit 1
fi

MOUNT_SOURCE="$(findmnt -T "$REAL_TESTDIR" -o SOURCE -n 2>/dev/null || echo unknown)"
MOUNT_FSTYPE="$(findmnt -T "$REAL_TESTDIR" -o FSTYPE -n 2>/dev/null || echo unknown)"
MOUNT_TARGET="$(findmnt -T "$REAL_TESTDIR" -o TARGET -n 2>/dev/null || echo unknown)"

CSV_HEADER='run_id,timestamp,datastore,profile,jobs,total_working_set_gib,read_mib_s,write_mib_s,total_mib_s,read_iops,write_iops,total_iops,read_mib_s_per_stream,write_mib_s_per_stream,read_iops_per_stream,write_iops_per_stream,read_p95_ms,read_p99_ms,write_p95_ms,write_p99_ms,primary_p95_ms,grade,status'
printf '%s\n' "$CSV_HEADER" > "$SUMMARY"

abort_now() {
  echo >&2
  echo "ABORTED. No further fio workloads will be started." >&2
  echo "The currently running fio process also receives the terminal signal." >&2
  echo "Benchmark files are intentionally left in place; no sync/rm is forced." >&2
  exit 130
}
trap abort_now INT TERM

{
  echo "VM Datastore Concurrency Benchmark - production-safe profile"
  echo "started=$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "run_id=$RUN_ID"
  echo "datastore_label=$LABEL"
  echo "host=$(hostname)"
  echo "fio=$(fio --version)"
  echo "testdir=$REAL_TESTDIR"
  echo "mount_source=$MOUNT_SOURCE"
  echo "mount_fstype=$MOUNT_FSTYPE"
  echo "mount_target=$MOUNT_TARGET"
  echo "gib_per_stream=$FILE_SIZE_GIB"
  echo "max_working_set_gib=$REQUIRED_GIB"
  echo "concurrency_levels=${JOBS[*]}"
  echo "runtime_seconds=$RUNTIME"
  echo "ramp_seconds=$RAMP"
  echo "max_io_latency=$MAX_IO_LATENCY"
  echo "stop_profile_at_p95_ms=$STOP_P95_MS"
  echo "prep_timeout=$PREP_TIMEOUT"
  echo
  df -hT "$REAL_TESTDIR" || true
  echo
  findmnt -T "$REAL_TESTDIR" || true
  echo
  lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL 2>/dev/null || lsblk
} > "$OUTDIR/metadata.txt"

cat <<BANNER

====================================================================
PRODUCTION-SAFE VM DATASTORE CONCURRENCY TEST
Datastore:       $LABEL
Target:          $REAL_TESTDIR
Backing mount:   $MOUNT_SOURCE ($MOUNT_FSTYPE)
Concurrency:     1, 5, 10, 15, 20, 25, 30, 35 streams
Working set:     ${FILE_SIZE_GIB} GiB/stream (${REQUIRED_GIB} GiB @ 35)
Measured step:   ${RUNTIME}s (+ ${RAMP}s ramp), hard wall guard ${STEP_TIMEOUT}s
Max fio latency: $MAX_IO_LATENCY (job aborts if exceeded)
Auto-stop:       stop higher levels in a profile at p95 >= ${STOP_P95_MS} ms
Results:         $OUTDIR
====================================================================

SAFETY MODEL
  boot:        QD1 -> at most 35 fio I/Os outstanding at 35 streams
  interactive: QD2 -> at most 70 fio I/Os outstanding at 35 streams
  install:     QD2 -> at most 70 fio I/Os outstanding at 35 streams
  prep:        QD1 -> at most 35 x 1 MiB writes outstanding

This MUST be a dedicated disposable benchmark filesystem.
Only files matching this prefix are created:
  ${FILE_PREFIX}.*

Ctrl-C stops the run. The script intentionally does NOT run sync or delete the
benchmark files on abort, so it does not create a second cleanup/reclaim storm.
BANNER

read -r -p "Type BENCHMARK to continue: " CONFIRM
if [[ "$CONFIRM" != "BENCHMARK" ]]; then
  echo "Cancelled."
  exit 1
fi

# Remove only stale benchmark files for this exact label. Do this before the
# test, while the datastore is idle, rather than after the stress run.
rm -f "${FILE_PREFIX}."* 2>/dev/null || true

# Prepare real blocks. 35 jobs x QD1 bounds the fio-side write queue to 35 MiB
# because each prep I/O is 1 MiB. Outer timeout prevents a sick array from
# spending the rest of the day on preparation.
echo
echo "[prep] Writing ${REQUIRED_GIB} GiB of benchmark data (35 jobs, QD1)."
echo "       Hard timeout: $PREP_TIMEOUT"
set +e
timeout --foreground --signal=INT --kill-after=10s "$PREP_TIMEOUT" \
  fio \
    --name=prep \
    --filename_format="${FILE_PREFIX}.\$jobnum" \
    --rw=write \
    --bs=1M \
    --size="${FILE_SIZE_GIB}G" \
    --numjobs="$MAX_JOBS" \
    --ioengine=libaio \
    --iodepth=1 \
    --direct=1 \
    --refill_buffers=1 \
    --scramble_buffers=1 \
    --randrepeat=0 \
    --group_reporting=1 \
    --eta=always \
    --output-format=json \
    --output="$OUTDIR/prep.json"
PREP_RC=$?
set -e
if (( PREP_RC != 0 )); then
  echo "Preparation did not complete (rc=$PREP_RC). Stopping safely." >&2
  echo "No measured workload will be started." >&2
  exit "$PREP_RC"
fi
sleep 10

run_one() {
  local profile="$1"
  local jobs="$2"
  local outfile="$OUTDIR/${profile}-jobs${jobs}.json"
  local working_set_gib=$((FILE_SIZE_GIB * jobs))
  local -a args=(
    --name="$profile"
    --filename_format="${FILE_PREFIX}.\$jobnum"
    --size="${FILE_SIZE_GIB}G"
    --numjobs="$jobs"
    --ioengine=libaio
    --direct=1
    --time_based=1
    --runtime="$RUNTIME"
    --ramp_time="$RAMP"
    --group_reporting=1
    --randrepeat=0
    --norandommap=1
    --lat_percentiles=1
    --percentile_list=50:95:99
    --max_latency="$MAX_IO_LATENCY"
    --eta=never
    --output-format=json
    --output="$outfile"
  )

  case "$profile" in
    boot)
      # Read-dominant, low-QD startup/application-launch pressure.
      args+=(--rw=randread --bssplit=4k/15:16k/25:64k/45:128k/15 --iodepth=1)
      ;;
    interactive)
      # Typical active VM pressure: mostly reads, modest queueing.
      args+=(--rw=randrw --rwmixread=80 --bssplit=4k/35:16k/30:64k/25:128k/10 --iodepth=2 --refill_buffers=1 --scramble_buffers=1)
      ;;
    install)
      # Install/update pressure: write-heavy, but still bounded to QD2/stream.
      args+=(--rw=randrw --rwmixread=30 --bssplit=4k/25:16k/25:64k/35:128k/15 --iodepth=2 --refill_buffers=1 --scramble_buffers=1)
      ;;
    *)
      echo "Unknown profile $profile" >&2
      return 2
      ;;
  esac

  echo
  echo "[$profile] $jobs stream(s), ${working_set_gib} GiB active set"
  set +e
  timeout --foreground --signal=INT --kill-after=10s "${STEP_TIMEOUT}s" fio "${args[@]}"
  local rc=$?
  set -e

  python3 - "$outfile" "$profile" "$jobs" "$working_set_gib" "$SUMMARY" "$RUN_ID" "$LABEL" "$rc" <<'PY'
import csv, datetime, json, os, sys

path, profile, jobs_s, ws_s, summary, run_id, label, rc_s = sys.argv[1:]
jobs_n = int(jobs_s)
ws = float(ws_s)
rc = int(rc_s)
status = 'ok' if rc == 0 else f'fio_rc_{rc}'

if not os.path.exists(path) or os.path.getsize(path) == 0:
    print(f"  fio did not produce usable JSON (rc={rc}).")
    sys.exit(10)

try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    print(f"  could not parse fio JSON: {e}")
    sys.exit(10)

records = data.get('jobs', [])
if not records:
    print("  fio JSON contains no job data")
    sys.exit(10)

def bw_mib(direction):
    total = 0.0
    for r in records:
        d = r.get(direction, {})
        if 'bw_bytes' in d:
            total += float(d.get('bw_bytes') or 0) / 1024 / 1024
        else:
            total += float(d.get('bw') or 0) / 1024
    return total

def iops(direction):
    return sum(float(r.get(direction, {}).get('iops') or 0) for r in records)

def pct_ms(direction, target):
    vals=[]
    for r in records:
        d=r.get(direction,{})
        got=None
        for key,scale in [('clat_ns',1e6),('clat_us',1e3),('clat_ms',1.0)]:
            obj=d.get(key,{})
            pct=obj.get('percentile',{}) if isinstance(obj,dict) else {}
            if pct:
                nearest=min(pct.keys(),key=lambda k:abs(float(k)-target))
                got=float(pct[nearest])/scale
                break
        if got is not None: vals.append(got)
    return max(vals) if vals else 0.0

rbw=bw_mib('read'); wbw=bw_mib('write')
ri=iops('read'); wi=iops('write')
r95=pct_ms('read',95); r99=pct_ms('read',99)
w95=pct_ms('write',95); w99=pct_ms('write',99)
primary = r95 if profile=='boot' else max(r95,w95)
if primary < 20: grade='GOOD'
elif primary < 50: grade='USABLE'
elif primary < 100: grade='DEGRADED'
else: grade='BAD'

row=[
    run_id, datetime.datetime.now().astimezone().isoformat(), label, profile, jobs_n,
    f'{ws:.3f}', f'{rbw:.2f}', f'{wbw:.2f}', f'{rbw+wbw:.2f}',
    f'{ri:.1f}', f'{wi:.1f}', f'{ri+wi:.1f}',
    f'{rbw/jobs_n:.2f}', f'{wbw/jobs_n:.2f}', f'{ri/jobs_n:.1f}', f'{wi/jobs_n:.1f}',
    f'{r95:.2f}', f'{r99:.2f}', f'{w95:.2f}', f'{w99:.2f}',
    f'{primary:.2f}', grade, status
]
with open(summary,'a',newline='',encoding='utf-8') as f:
    csv.writer(f).writerow(row)

print(f"  aggregate: read={rbw:.1f} MiB/s write={wbw:.1f} MiB/s IOPS={ri+wi:.0f}")
print(f"  per stream: read={rbw/jobs_n:.1f} MiB/s write={wbw/jobs_n:.1f} MiB/s IOPS={(ri+wi)/jobs_n:.0f}")
print(f"  p95: read={r95:.1f} ms write={w95:.1f} ms primary={primary:.1f} ms [{grade}] status={status}")
print(f"PRIMARY_P95={primary:.3f}")
PY
  local parse_rc=$?

  if (( parse_rc != 0 )); then
    echo "  Could not extract reliable stats. Stop higher concurrency for this profile."
    return 3
  fi

  local p95
  p95=$(tail -n 1 <(python3 - "$SUMMARY" "$profile" "$jobs" <<'PY'
import csv,sys
p,j=sys.argv[2],sys.argv[3]
with open(sys.argv[1],newline='',encoding='utf-8') as f:
    rows=[r for r in csv.DictReader(f) if r['profile']==p and r['jobs']==j]
print(rows[-1]['primary_p95_ms'] if rows else '999999')
PY
))

  # Any nonzero fio status means timeout/max-latency/etc. Don't increase load.
  if (( rc != 0 )); then
    echo "  SAFETY STOP: fio returned rc=$rc. Not testing higher $profile concurrency."
    return 4
  fi

  if python3 - "$p95" "$STOP_P95_MS" <<'PY'
import sys
sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
PY
  then
    echo "  SAFETY STOP: p95 ${p95} ms >= ${STOP_P95_MS} ms."
    echo "  Higher $profile concurrency will be skipped."
    return 5
  fi

  sleep "$PAUSE"
  return 0
}

for profile in "${PROFILES[@]}"; do
  echo
  echo "================ PROFILE: $profile ================"
  for jobs in "${JOBS[@]}"; do
    set +e
    run_one "$profile" "$jobs"
    rc=$?
    set -e
    if (( rc != 0 )); then
      break
    fi
  done
  sleep "$PAUSE"
done

# Human-readable report and master CSV.
python3 - "$SUMMARY" "$REPORT" "$MASTER_CSV" "$CSV_HEADER" "$LABEL" "$RUN_ID" <<'PY'
import csv, os, sys
summary, report, master, header_line, label, run_id = sys.argv[1:]
with open(summary,newline='',encoding='utf-8') as f:
    rows=list(csv.DictReader(f))

master_exists=os.path.exists(master) and os.path.getsize(master)>0
with open(master,'a',newline='',encoding='utf-8') as f:
    w=csv.DictWriter(f,fieldnames=header_line.split(','))
    if not master_exists: w.writeheader()
    for r in rows: w.writerow(r)

lines=[]
lines.append('='*86)
lines.append(f'PRODUCTION-SAFE VM DATASTORE REPORT: {label}')
lines.append(f'Run: {run_id}')
lines.append('='*86)
lines.append('')
for profile in ('boot','interactive','install'):
    rs=[r for r in rows if r['profile']==profile]
    if not rs: continue
    rs.sort(key=lambda r:int(r['jobs']))
    lines.append(f'[{profile}]')
    lines.append(f"{'VMs':>4} {'SetGiB':>7} {'ReadMiB/s':>10} {'WriteMiB/s':>11} {'IOPS':>9} {'p95ms':>8} {'Grade':>9} {'Status':>12}")
    lines.append('-'*80)
    for r in rs:
        lines.append(f"{int(r['jobs']):4d} {float(r['total_working_set_gib']):7.1f} {float(r['read_mib_s']):10.1f} {float(r['write_mib_s']):11.1f} {float(r['total_iops']):9.0f} {float(r['primary_p95_ms']):8.1f} {r['grade']:>9} {r['status']:>12}")
    good=[int(r['jobs']) for r in rs if r['grade'] in ('GOOD','USABLE') and r['status']=='ok']
    if good:
        lines.append(f'  Highest tested GOOD/USABLE point: {max(good)} streams')
    last=rs[-1]
    if int(last['jobs'])<35:
        lines.append(f"  Sweep stopped before 35 at {last['jobs']} streams due to safety criteria.")
    lines.append('')
lines.append('Interpretation: use the highest stable point as a synthetic starting estimate, then')
lines.append('validate with actual simultaneous VM boots. This test includes the benefit of TrueNAS ARC.')
lines.append('')
lines.append('Benchmark files were intentionally KEPT. Delete them later, when the datastore is not')
lines.append('about to return to production, rather than forcing cleanup/reclaim immediately after stress.')
lines.append('='*86)
text='\n'.join(lines)+'\n'
with open(report,'w',encoding='utf-8') as f: f.write(text)
print(text)
PY

echo
echo "FINISHED SAFELY: $LABEL"
echo "Summary CSV: $SUMMARY"
echo "Report:      $REPORT"
echo "Master CSV:  $MASTER_CSV"
echo
echo "Benchmark files remain in place at:"
echo "  ${FILE_PREFIX}.*"
echo "Delete them later during a quiet period, e.g.:"
echo "  sudo rm -f '${FILE_PREFIX}.'*"
echo
