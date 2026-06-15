#!/bin/sh
# Realistic benchmark: virtiofs bind (= "raw" in production) vs FUSE-over-virtiofs.
# /data is the host bind. Backing for FUSE = /data; mount = /mnt.
set -eu

apk add --no-cache fuse3 git >/dev/null 2>&1

DATA=/data            # host bind mount
MNT=/mnt
mkdir -p "$MNT"

# clean any prior dataset
rm -rf "$DATA"/synthetic "$DATA"/express "$DATA"/wb 2>/dev/null || true

echo "=== generating dataset on virtiofs bind ==="
mkdir -p "$DATA/synthetic"
( cd "$DATA/synthetic"
  for d in $(seq 1 50); do
    mkdir -p "dir-$d"
    for f in $(seq 1 200); do
      printf 'line one\nline two\nline three line three\nfourth\nfifth\n' > "dir-$d/file-$f.txt"
    done
  done
)
total=$(find "$DATA/synthetic" -type f | wc -l)
echo "files: $total"
du -sh "$DATA/synthetic" 2>&1 | head -1

# launch rp-fuse
/tools/rp-fuse --backing "$DATA" --mount "$MNT" &
FPID=$!
for i in 1 2 3 4 5 10; do
  mountpoint -q "$MNT" && break
  sleep 0.2
done
mountpoint -q "$MNT" || { echo FAIL; exit 1; }
echo "fuse mounted"
echo

timeit() {
  # $1=cwd  $2..=command
  cd_to=$1; shift
  /usr/bin/time -f '%e' sh -c "cd '$cd_to' && $* >/dev/null 2>&1" 2>&1
}

run3() {
  # $1 label, $2 path, rest = command (single string)
  label=$1; path=$2; shift 2
  cmd=$*
  cd "$path" && eval "$cmd" >/dev/null 2>&1 || true   # warm-up
  t1=$(timeit "$path" "$cmd")
  t2=$(timeit "$path" "$cmd")
  t3=$(timeit "$path" "$cmd")
  printf "  %-25s %s %s %s\n" "$label" "$t1" "$t2" "$t3"
}

echo "=== read benchmarks (3 runs each, seconds) ==="
for backend in raw fuse; do
  case $backend in
    raw)  path=$DATA/synthetic ;;
    fuse) path=$MNT/synthetic ;;
  esac
  echo "[$backend] $path"
  run3 "find -type f"        "$path" "find . -type f"
  run3 "find+stat (wc -l)"   "$path" "find . -type f -exec wc -l {} +"
  run3 "cat-all"             "$path" "find . -type f -exec cat {} +"
  run3 "grep -r 'three'"     "$path" "grep -r 'three' ."
  run3 "tar cf -"            "$path" "tar cf /tmp/out.tar ."
  run3 "du -s"               "$path" "du -s ."
done

echo
echo "=== write benchmarks ==="
write_bench() {
  label=$1; path=$2
  rm -rf "$path/wb" 2>/dev/null
  mkdir -p "$path/wb"
  t=$(/usr/bin/time -f '%e' sh -c "
    cd '$path/wb'
    for d in \$(seq 1 20); do mkdir -p d-\$d; for f in \$(seq 1 100); do echo hello > d-\$d/f-\$f; done; done
  " 2>&1)
  printf "  %-25s %s\n" "$label create 20*100" "$t"
  t=$(/usr/bin/time -f '%e' sh -c "rm -rf '$path/wb'" 2>&1)
  printf "  %-25s %s\n" "$label rm -rf" "$t"
}
write_bench "raw"  "$DATA"
write_bench "fuse" "$MNT"

echo
echo "=== git status x3 on real repo ==="
git clone --depth=20 https://github.com/expressjs/express "$DATA/express" 2>&1 | tail -1
for backend in raw fuse; do
  case $backend in
    raw)  path=$DATA/express ;;
    fuse) path=$MNT/express ;;
  esac
  t=$(/usr/bin/time -f '%e' sh -c "cd '$path' && git status >/dev/null && git status >/dev/null && git status >/dev/null" 2>&1)
  printf "  %-25s %s\n" "$backend" "$t"
done

echo
echo "=== unmount + cleanup ==="
fusermount3 -u "$MNT"
wait $FPID 2>/dev/null || true
rm -rf "$DATA/synthetic" "$DATA/express" "$DATA/wb"
echo DONE
