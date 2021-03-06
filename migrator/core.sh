# Migrator Core
# Copyright (C) 2018-2019, VR25 @ xda-developers
# License: GPL V3+


modId=migrator
tmpDir=/dev/$modId
rsync=$modPath/bin/rsync
modData=/data/media/$modId
config=$modData/config.txt
backupsDir=$modData/backups
backupsDirOrig=$backupsDir
pkgList=/data/system/packages.list
failedRes=$modData/failed_restores
migratedData=$modData/migrated_data
defaultConfig=$modPath/default_config.txt


# preparation
mkdir -p $tmpDir
[ -f $modData/.nomedia ] || touch $modData/.nomedia
[ -f $config ] || cp $defaultConfig $config


# backup frequency in hours
bkpFreq=$(sed -n 's/^bkpFreq=//p' $config)


backup() {
  local pkg="" thread=0
  local threads=$(( $(sed -n 's/^threads=//p' $config) - 1 )) || :
  if grep -q '^inc' $config 2>/dev/null; then
    echo "(i) Backing up (using $((threads + 1)) threads)..."
    set +e
    rm -rf $backupsDir.old 2>/dev/null
    mv $backupsDir $backupsDir.old 2>/dev/null
    mkdir -p $backupsDir
    set -e
    for pkg in $(awk '{print $1}' $pkgList); do
      [ $thread -gt $threads ] && { wait; thread=0; }
      if ! grep "\"$pkg\" codePath" /data/system/packages.xml | grep -q 'codePath=\"/data/'; then
        if match_test inc $pkg && ! match_test exc $pkg; then
          thread=$(( thread + 1 )) || :
          (pkg=$pkg; apps_and_data) &
        fi
      else
        if ! match_test exc $pkg; then
          if grep -q '^inc --user' $config || match_test inc $pkg; then
            thread=$(( thread + 1 )) || :
            (pkg=$pkg; apps_and_data) &
          fi
        fi
      fi
    done
    wait
  fi
  if grep -q '^bkp ' $config; then
    echo
    sed -n "s:^bkp:$rsync -rtu --inplace:p" \
    $config > $tmpDir/rsync_bkp
    . $tmpDir/rsync_bkp
  fi
  if [ ${1:-x} != ondemand ]; then
    sleep $((bkpFreq * 3600))
    cp -f $log $log.old && : > $log || :
    backup
  fi
}


apps_and_data() {
  echo "  - $pkg"
  cp -al /data/data/$pkg $backupsDir/
  set +eo pipefail
  ! grep "\"$pkg\" codePath" /data/system/packages.xml | grep -q 'codePath=\"/data/' \
    || cp -al $(grep "\"$pkg\" codePath" /data/system/packages.xml | awk '{print $3}' | sed 's/codePath="//;s/"//')/base.apk \
      $backupsDir/$pkg.apk 2>/dev/null
  set -eo pipefail
}


onboot() {
  if [ ${1:-x} != ondemand ]; then
    restore_on_boot
    retry_failed_restores
    ! grep -iq '^noAutoBkp' $config || exit 0
    sleep $(( $(sed -n s/firstBkpDelayH=//p $config.txt) * 60 * 60 )) 2>/dev/null \
      || sleep 7200 # 2 hours (default)
    (backup 1>/dev/null &) &
  else
    backup $1
  fi
  [ ${1:-x} = ondemand ] && { echo; echo; exit_or_not; }
}


restore_on_boot() {
  local pkg="" owner=""
  if ls -p $migratedData 2>/dev/null | grep -q / \
    && ! grep -iq '^noapps' $config
  then
    set +eo pipefail
    for pkg in $(ls -1p $migratedData | grep / | tr -d /); do
      if [ -f $migratedData/$pkg.apk ]; then
        if grep -q "^$pkg " $pkgList; then
          pm install -r $migratedData/$pkg.apk 1>/dev/null
        else
          pm install $migratedData/$pkg.apk 1>/dev/null
        fi
        if [ $? -eq 0 ]; then
          rm $migratedData/$pkg.apk
          refresh_apk_backups $pkg
        fi
      fi
      if grep -q "^$pkg " $pkgList; then
        pm disable $pkg 1>/dev/null
        rm -rf /data/data/$pkg
        mv $migratedData/$pkg /data/data/
        rm /data/data/$pkg/shared_prefs/com.google.android.gms.appid.xml 2>/dev/null
        owner=$(grep "^$pkg " $pkgList | awk '{print $2}')
        chown -R $owner:$owner /data/data/$pkg 2>/dev/null
        chmod -R 0771 /data/data/$pkg 2>/dev/null
        restorecon -R /data/data/$pkg 2>/dev/null
        symlink_lib $pkg
        pm enable $pkg 1>/dev/null
      else
        mkdir -p $failedRes
        grep "$pkg " $log > $failedRes/$pkg.log
        mv $migratedData/$pkg* $failedRes/
      fi
    done
    rm -rf $migratedData
    set -eo pipefail
  fi
}


retry_failed_restores() {
  local restoreAttempts=1
  while [ $restoreAttempts -lt $(sed -n s/autoRestoreAttempts=//p $config.txt) ]; do
    if mv $failedRes $migratedData 2>/dev/null; then
      restore_on_boot
    else
      break
    fi
    restoreAttempts=$(( restoreAttempts + 1 ))
  done
  if [ -d $failedRes ]; then
    rm -rf $failedRes.old 2>/dev/null || :
    mv $failedRes $failedRes.old 2>/dev/null || :
  fi
}


# $1 -- <inc or exc>
# $2 -- <package name>
match_test() {
  local target=""
  for target in $(sed -n "s/^$1 //p" $config); do
    echo $2 | grep -Eq "$target" 2>/dev/null && return 0 || :
  done
  return 1
}


# $1 -- <package name>
symlink_lib() {
  local lib=$(grep "\"$pkg\" codePath" /data/system/packages.xml | awk '{print $4}' | sed 's/native[^=]*="//;s/"//')
  ln -fs $lib/* /data/data/$1/lib 2>/dev/null
}


# $1 -- <package name>
refresh_apk_backups() {
  if grep -q "^$1 " $pkgList; then
    rm $backupsDirOrig/$1.apk 2>/dev/null \
      && cp -al $(grep name=\"$1\" /data/system/packages.xml | awk '{print $3}' | sed 's/codePath="//;s/"//')/base.apk \
        $backupsDirOrig/$1.apk
    rm $backupsDirOrig.old/$1.apk 2>/dev/null \
      && cp -al $(grep name=\"$1\" /data/system/packages.xml | awk '{print $3}' | sed 's/codePath="//;s/"//')/base.apk \
        $backupsDirOrig.old/$1.apk
  fi
}
