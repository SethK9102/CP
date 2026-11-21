#!/bin/sh
export PAGER=cat

LOG=/root/cp-log.txt
README_CACHE=/root/cp-readme.html
UA='Mozilla/5.0 (X11; FreeBSD amd64; rv:128.0) Gecko/20100101 Firefox/128.0'
ME=${SUDO_USER:-${DOAS_USER:-$(logname 2>/dev/null)}}
[ "$ME" = root ] && ME=''
AUTH='' ADMINS=''
TMPD=$(mktemp -d /tmp/cp.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }
ask() { local a; printf '%s [y/N] ' "$1" >&2; read -r a; case $a in [yY]*) return 0 ;; esac; return 1; }
prompt() { printf '%s' "$2" >&2; read -r "$1"; }
prompt_names() {
  while prompt "$1" "$2"; do
    eval "case \${$1} in [yY]|[yY][eE][sS]|[nN]|[nN][oO]) ;; *) return 0 ;; esac"
    echo "That looks like a yes/no answer. Press Enter to use the lists, or type the usernames." >&2
  done
}
hdr() { printf '\n===== %s =====\n' "$*"; }
in_list() { local x=$1 y; shift; for y; do [ "$x" = "$y" ] && return 0; done; return 1; }
have_pkg() { pkg -N >/dev/null 2>&1; }
pkg_installed() { have_pkg && pkg info -e "$1" 2>/dev/null; }

set_kv() {
  local f=$1 k=$2 v=$3 s=${4:- }
  [ -f "$f" ] || return 0
  if grep -Eq "^[#[:space:]]*$k([[:space:]]|=)" "$f"; then
    sed -i '' -E "s@^[#[:space:]]*$k([[:space:]]|=).*@$k$s$v@" "$f"
  else
    printf '%s%s%s\n' "$k" "$s" "$v" >> "$f"
  fi
  log "$f: $k$s$v"
}

ini_set() {
  local f=$1 sec=$2 k=$3 v=$4
  [ -f "$f" ] || return 0
  awk -v sec="$sec" -v k="$k" -v v="$v" '
    function out() { print k " = " v; done = 1 }
    /^[ \t]*\[/ {
      if (insec && !done) out()
      insec = (tolower($0) ~ "^[ \t]*\\[" tolower(sec) "\\]")
      print; next
    }
    insec && !done && tolower($0) ~ "^[ \t]*[#;]?[ \t]*" tolower(k) "[ \t]*=" { out(); next }
    { print }
    END { if (insec && !done) out(); if (!done) { print "[" sec "]"; out() } }' "$f" > "$f.cp" &&
    cat "$f.cp" > "$f" && rm -f "$f.cp"
  log "$f [$sec] $k = $v"
}

rc_set() { sysrc "$@" >/dev/null && log "rc.conf: $*"; }

unowned() {
  if [ ! -f "$TMPD/owned" ]; then
    if have_pkg; then pkg query '%Fp' 2>/dev/null | sort -u > "$TMPD/owned"; else : > "$TMPD/owned"; fi
  fi
  sort -u | comm -23 - "$TMPD/owned"
}

review_lines() {
  local hits hit f n
  hits=$(printf '%s\n' "$1" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep . | sort -u)
  [ -n "$hits" ] || { echo "  none"; return; }
  while IFS= read -r hit <&3; do
    f=${hit%%:*}
    n=${hit#*:}
    n=${n%%:*}
    echo "$hit"
    case $n in ''|*[!0-9]*) continue ;; esac
    ask "  Comment out line $n of $f?" && sed -i '' "${n}s/^/#/" "$f" && log "commented out $f:$n"
  done 3<<EOF
$hits
EOF
}

review_files() {
  local f
  [ -n "$1" ] || { echo "  none"; return; }
  while IFS= read -r f <&3; do
    [ -e "$f" ] || continue
    echo "--- $f"
    if grep -Iq . "$f" 2>/dev/null; then head -n 15 "$f"; else file -b "$f" 2>/dev/null || echo "  (binary file)"; fi
    ask "  Delete $f?" && rm -f -- "$f" && log "deleted $f"
  done 3<<EOF
$1
EOF
}

saved_readme() {
  find /home/*/Desktop /home/*/Downloads /home/* /root/Desktop /root -maxdepth 1 -type f \
      \( -iname '*readme*' -o -iname '*.htm' -o -iname '*.html' -o -iname '*.mhtml' \) ! -name '*.desktop' \
      -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | cut -d' ' -f2- |
    while IFS= read -r f; do
      case $f in *[Rr][Ee][Aa][Dd][Mm][Ee]*) echo "$f"; break ;; esac
      grep -qi 'Authorized Administrators' "$f" && { echo "$f"; break; }
    done
}

fetch_readme() {
  local url=$1 page saved a
  while :; do
    page=$(fetch -q -o - --user-agent="$UA" "$url" 2>"$TMPD/fetch.err") ||
      page=$(fetch -q -o - --no-verify-peer --user-agent="$UA" "$url" 2>>"$TMPD/fetch.err")
    if printf '%s\n' "$page" | grep -qi 'Authorized'; then printf '%s\n' "$page"; return 0; fi
    saved=$(saved_readme)
    if [ -n "$saved" ] && grep -qi 'Authorized' "$saved"; then
      echo "README: using the saved copy $saved" >&2
      cat "$saved"; return 0
    fi
    sort -u "$TMPD/fetch.err" >&2
    echo "README: could not download it (a web filter or sign-in page may be in the way)." >&2
    echo "README: open the README in the browser, save it with Ctrl+S (Desktop or Downloads, any name)," >&2
    prompt a "README: then press Enter to try again, or type s to skip and type the users yourself: "
    case $a in [sS]*) return 1 ;; esac
  done
}

html_text() {
  sed -E -e 's/<[hH][1-6][^>]*>/\
== /g' -e 's#<(br|/p|li|/li|/div|/tr|/td|/h[1-6]|pre|/pre)[^>]*>#\
#gI' -e 's/<[^>]*>//g' \
    -e 's/&nbsp;|&#160;/ /g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;|&ldquo;|&rdquo;/"/g' \
    -e "s/&#39;|&lsquo;|&rsquo;/'/g" -e 's/&amp;/\&/g' | tr -d '\r' | grep -v '^[[:space:]]*$'
}

readme_text() {
  local f=${README:-} url page
  if [ -z "$f" ]; then
    if [ -s "$README_CACHE" ] && grep -qi 'Authorized' "$README_CACHE"; then f=$README_CACHE
    else
      f=$(saved_readme)
      [ -n "$f" ] || f=$(find /home/*/Desktop /root/Desktop -maxdepth 1 \( -type f -o -type l \) -iname '*readme*' 2>/dev/null | sort | head -n1)
    fi
  fi
  if [ ! -f "$f" ]; then
    echo "README: none found on a Desktop. Run again as: README=/path/to/file sh cp-freebsd.sh" >&2
    return 0
  fi
  case $f in
    *.desktop)
      url=$(sed -nE 's/^(URL|Exec)(\[[^]]*\])?=//p' "$f" | grep -oE "(https?|file)://[^\"' ]+|/[^\"' ]+\.(html?|txt|aspx)" | head -n1 | sed 's/%20/ /g')
      echo "README: $f -> ${url:-no link found}" >&2
      case $url in
        file://*) page=$(cat "${url#file://}") ;;
        /*) page=$(cat "$url") ;;
        http*) page=$(fetch_readme "$url") || return 0 ;;
      esac
      printf '%s\n' "$page" | grep -qi 'Authorized' && printf '%s\n' "$page" > "$README_CACHE"
      printf '%s\n' "$page" | html_text ;;
    *)
      echo "README: $f" >&2
      html_text < "$f" ;;
  esac
}

readme_names() {
  printf '%s\n' "$1" | awk -v h="$2:" '
    !on && index($0, h) {on=1; $0 = substr($0, index($0, h) + length(h)); if ($0 !~ /[^[:space:]]/) next}
    !on || /^[[:space:]]*$/ || tolower($1) ~ /^password/ {next}
    /Authorized/ || $1 !~ /^[a-z_][a-z0-9_.-]*$/ {exit}
    {print $1}'
}

readme_groups() {
  printf '%s\n' "$1" | LC_ALL=C sed -e 's/“/"/g' -e 's/”/"/g' -e "s/‘/'/g" -e "s/’/'/g" | awk '
    function emit() { if (g != "") print g "|" m; g = ""; m = ""; want = 0 }
    function add(w) { gsub(/^[^A-Za-z0-9_]+|[^A-Za-z0-9_]+$/, "", w); if (w ~ /^[a-z_][a-z0-9_.-]*$/ && w != "and") m = (m == "" ? w : m " " w) }
    want {
      if ($0 ~ /^[ \t]*[a-z_][a-z0-9_.-]*[ \t]*$/) { add($0); next }
      emit()
    }
    {
      l = tolower($0)
      if (!match(l, /create (a |the )?(new )?([a-z]+ )?group ((called|named) ["\047]?[a-z0-9_.-]+|["\047][a-z0-9_.-]+)/)) next
      s = substr($0, RSTART, RLENGTH)
      sub(/^.*[Gg][Rr][Oo][Uu][Pp] /, "", s); sub(/^([Cc]alled|[Nn]amed) /, "", s); gsub(/["\047]/, "", s)
      g = s; m = ""
      c = index($0, ":")
      if (c) {
        rest = substr($0, c + 1)
        if (rest ~ /^[ \t]*$/) { want = 1; next }
        n = split(rest, a, /[ \t,]+/)
        for (i = 1; i <= n; i++) add(a[i])
      }
      emit()
    }
    END { emit() }'
}

readme_todo() {
  printf '%s\n' "$1" |
    grep -iE '(^|[^a-z])(create|install|update|up.to.date|keep|kept|enable|disable|default|must|should|not authori[sz]ed|prohibited|remove)([^a-z]|$)' |
    grep -viE 'forensics|unique identifier|scoring report|CCS Client|time ?zone|JavaScript|Stop Scoring|home directories|auto-?login|scoring engine'
}

readme_service_text() {
  local s
  s=$(printf '%s\n' "$1" | awk '
    tolower($0) ~ /critical services/ {on=1; sub(/.*[Cc]ritical [Ss]ervices:?/, ""); if ($0 ~ /[^[:space:]]/) print; next}
    on && (/^== / || /:[[:space:]]*$/) {exit}
    on {print}')
  if [ -n "$(printf '%s' "$s" | tr -d '[:space:]')" ]; then printf '%s\n' "$s"; else printf '%s\n' "$1"; fi
}

step_audit() {
  hdr "pkg repositories (only the official FreeBSD ones should be listed)"
  have_pkg && pkg -vv 2>/dev/null | sed -n '/^Repositories:/,$p'
  hdr "Listening ports"
  sockstat -46l
  hdr "UID 0 accounts other than root (toor is normal while its password is *)"
  awk -F: '$3==0 && $1!="root" {print $1, ($2 ~ /^\*/ ? "(cannot log in)" : "(CAN LOG IN)")}' /etc/master.passwd
  hdr "System accounts (UID<1000) with a login shell"
  awk -F: '$3>0 && $3<1000 && $7 !~ /(nologin|false|uucico)$/ {print $1, $7}' /etc/passwd
  hdr "Accounts with empty passwords"
  awk -F: '$2=="" {print $1}' /etc/master.passwd
  hdr "Weak password hashes (not SHA-512 or bcrypt; fix by setting a new password)"
  awk -F: '$2!="" && $2 !~ /^\*/ && $2 !~ /^\$(6|2[aby]?)\$/ {print $1}' /etc/master.passwd
  hdr "Duplicate UIDs, GIDs or names"
  cut -d: -f3 /etc/passwd | sort | uniq -d | sed 's/^/UID /'
  cut -d: -f1 /etc/passwd | sort | uniq -d | sed 's/^/user /'
  cut -d: -f3 /etc/group | sort | uniq -d | sed 's/^/GID /'
  cut -d: -f1 /etc/group | sort | uniq -d | sed 's/^/group /'
  hdr "Members of wheel, operator and kmem"
  grep -E '^(wheel|operator|kmem):' /etc/group
  hdr "/etc/hosts entries"
  grep -vE '^[[:space:]]*(#|$)' /etc/hosts
  hdr "World-writable files in /etc and /usr/local/etc"
  find /etc /usr/local/etc -type f -perm -0002 2>/dev/null
  hdr "Enabled services"
  service -e | sed 's#.*/##' | xargs
  hdr "Packages with known vulnerabilities (from the last pkg audit database)"
  have_pkg && pkg audit 2>/dev/null | tail -n 15
  local todo
  todo=$(readme_todo "$(readme_text)")
  if [ -n "$todo" ]; then
    hdr "README instructions to check off (the script does not do all of these)"
    printf '%s\n' "$todo" | sed 's/^/  - /'
  fi
  prompt _ "Press Enter to continue..."
}

step_repos() {
  hdr "pkg repositories"
  local f
  if ! have_pkg; then echo "pkg is not set up yet (the updates step can bootstrap it)."; return; fi
  pkg -vv 2>/dev/null | sed -n '/^Repositories:/,$p'
  pkg -vv 2>/dev/null | awk '/^[ \t]+FreeBSD(-ports)?: \{/ {b = 1; next} b && /enabled/ {if (/yes/) ok = 1; b = 0} END {exit !ok}' ||
    echo "The official FreeBSD package repo is turned off. Look for 'enabled: no' below."
  echo "Lines that turn signature checks off, point somewhere other than pkg.FreeBSD.org, or turn a repo off:"
  review_lines "$(grep -nHisE 'signature_type:[[:space:]]*"?none|url:' /etc/pkg/*.conf /usr/local/etc/pkg/repos/*.conf |
      grep -viE 'url:[[:space:]]*"pkg\+https?://pkg\.freebsd\.org/'
    grep -nHisE 'enabled:[[:space:]]*"?(no|false)' /usr/local/etc/pkg/repos/*.conf)"
  hdr "Repo files that add repos other than FreeBSD's own"
  review_files "$(for f in /usr/local/etc/pkg/repos/*.conf; do
      [ -f "$f" ] || continue
      grep -vE '^[[:space:]]*#' "$f" | grep -oE '^[[:space:]]*"?[A-Za-z0-9_.-]+"?[[:space:]]*:[[:space:]]*\{' | tr -d ' \t"{:' |
        grep -qvxE 'FreeBSD|FreeBSD-ports|FreeBSD-ports-kmods|FreeBSD-kmods|FreeBSD-base' && echo "$f"
    done)"
  hdr "pkg.conf settings that move where pkg looks for repos or keys"
  f=/usr/local/etc/pkg.conf
  [ -f $f ] && review_lines "$(grep -nHE '^[[:space:]]*(REPOS_DIR|PACKAGESITE|PUBKEY|FINGERPRINTS|SIGNATURE_TYPE|PKG_ENV|ABI|ALTABI)[[:space:]]*[:=]' $f)"
}

cp_group() {
  local g=$1 m=$2 u have
  if ! pw groupshow "$g" >/dev/null 2>&1; then
    ask "  Create group '$g'?" || return 0
    pw groupadd -n "$g" && log "created group $g" || return 0
  fi
  have=$(pw groupshow "$g" | cut -d: -f4 | tr , ' ')
  for u in $m; do
    in_list "$u" $have && continue
    id "$u" >/dev/null 2>&1 || { echo "  no user '$u': create it first (it must be in the authorized list)"; continue; }
    pw groupmod "$g" -m "$u" && log "added $u to $g"
  done
  for u in $have; do
    in_list "$u" $m && continue
    ask "  '$u' is in $g but not in the list. Remove?" && pw groupmod "$g" -d "$u" && log "removed $u from $g"
  done
}

step_users() {
  hdr "Users"
  local text admins users a u g pw nu home uid shell gname gmem line chg
  text=$(readme_text)
  admins=$(readme_names "$text" "Authorized Administrators" | xargs)
  users=$(readme_names "$text" "Authorized Users" | xargs)
  [ -n "$ME" ] || ME=$(printf '%s\n' "$text" | grep -m1 '(you)' | awk '{print $1}')
  if [ -n "$admins$users" ]; then echo "Parsed from README. Check against the README and retype if wrong."
  else echo "Could not read README users. Type them in."; fi
  echo "  admins: $admins"
  echo "  users : $users"
  echo "Also include any account the README tells you to create."
  prompt_names a "Enter = use both lists above, or type ALL authorized usernames (admins too): "
  AUTH=${a:-"$admins $users"}
  prompt_names a "Enter = use the README admins, or type the admins: "
  ADMINS=${a:-$admins}
  [ -n "$ME" ] || prompt ME "Your own login username: "
  if [ -z "$(echo $AUTH)" ]; then echo "No users entered, skipping."; return; fi
  AUTH=$(printf '%s\n' $AUTH $ME | sort -u | xargs)
  ADMINS=$(printf '%s\n' $ADMINS $ME | sort -u | xargs)

  for u in $(awk -F: '$3>=1000 && $3!=65534 {print $1}' /etc/passwd); do
    in_list "$u" $AUTH && continue
    ask "Delete unauthorized user '$u'?" && pw userdel -n "$u" -r && log "deleted user $u"
  done

  for u in $(awk -F: '$3==0 && $1!="root" {print $1}' /etc/master.passwd); do
    if [ "$u" = toor ]; then
      case $(awk -F: '$1=="toor" {print $2}' /etc/master.passwd) in '*'*) continue ;; esac
      ask "toor (FreeBSD's spare root account) can log in. Turn its password off?" && pw usermod -n toor -w no && log "toor: password off"
      continue
    fi
    if in_list "$u" $AUTH; then
      nu=$(awk -F: '$3>=1000 && $3<60000 {print $3}' /etc/passwd | sort -n | tail -n1)
      nu=$(( ${nu:-1000} + 1 ))
      ask "Authorized user '$u' has UID 0 (full root powers). Give it UID $nu?" || continue
      g=$(awk -F: -v u="$u" '$1==u {print $4}' /etc/passwd)
      if [ "$g" = 0 ]; then
        pw groupshow "$u" >/dev/null 2>&1 || pw groupadd -n "$u"
        pw usermod -n "$u" -u "$nu" -g "$u"
      else
        pw usermod -n "$u" -u "$nu"
      fi && log "UID of $u: 0 -> $nu"
      home=$(awk -F: -v u="$u" '$1==u {print $6}' /etc/passwd)
      case $home in /home/*|/usr/home/*) [ -d "$home" ] && chown -R "$u:" "$home" ;; esac
    else
      ask "'$u' has UID 0, a second root account. Delete it?" || continue
      pw userdel -n "$u" 2>/dev/null || { sed -i '' "/^$u:/d" /etc/master.passwd && pwd_mkdb -p /etc/master.passwd; }
      log "deleted UID 0 account $u"
    fi
  done

  awk -F: '$3>0 && $3<1000 && $7 !~ /(nologin|false|uucico)$/ {print $1":"$3":"$7":"$6}' /etc/passwd > "$TMPD/hidden"
  while IFS=: read -r u uid shell home <&3; do
    in_list "$u" $AUTH && continue
    echo "Hidden account '$u': UID $uid (system range) but it can log in (shell $shell, home $home)"
    prompt a "  (d)elete it, (l)ock it (no shell, no password), (k)eep? [k] "
    case $a in
      d*) case $home in /home/*|/usr/home/*) pw userdel -n "$u" -r ;; *) pw userdel -n "$u" ;; esac && log "deleted hidden account $u" ;;
      l*) pw usermod -n "$u" -s /usr/sbin/nologin -w no && log "locked hidden account $u" ;;
    esac
  done 3< "$TMPD/hidden"

  for u in $AUTH; do
    id "$u" >/dev/null 2>&1 && continue
    ask "README user '$u' missing. Create?" && pw useradd -n "$u" -m -s /bin/sh && log "created user $u"
  done

  for g in wheel operator kmem; do
    for u in $(pw groupshow "$g" 2>/dev/null | cut -d: -f4 | tr , ' '); do
      [ "$u" = root ] && continue
      [ "$g" != kmem ] && in_list "$u" $ADMINS && continue
      ask "Remove '$u' from group $g?" && pw groupmod "$g" -d "$u" && log "removed $u from $g"
    done
  done
  for u in $(awk -F: '$4==0 && $3>=1000 {print $1}' /etc/passwd); do
    ask "'$u' has wheel as its primary group. Give it its own group?" || continue
    pw groupshow "$u" >/dev/null 2>&1 || pw groupadd -n "$u"
    pw usermod -n "$u" -g "$u" && log "primary group of $u -> $u"
  done
  for u in $ADMINS; do
    id "$u" >/dev/null 2>&1 || continue
    id -Gn "$u" | tr ' ' '\n' | grep -qx wheel && continue
    ask "Add admin '$u' to wheel (lets them su to root)?" && pw groupmod wheel -m "$u" && log "added $u to wheel"
  done

  readme_groups "$text" > "$TMPD/groups"
  [ -s "$TMPD/groups" ] || echo "README asks for no new groups (that the script could find)."
  while IFS= read -r line <&3; do
    gname=${line%%|*} gmem=${line#*|}
    echo "README group '$gname' with members: $gmem"
    prompt a "  Group name (Enter = $gname): "; gname=${a:-$gname}
    prompt a "  Members (Enter = the list above, or type them space-separated): "; gmem=${a:-$gmem}
    cp_group "$gname" "$gmem"
  done 3< "$TMPD/groups"
  while :; do
    prompt gname "Another group the README asks for (name, Enter = none): "
    [ -n "$gname" ] || break
    prompt gmem "  Members (space-separated): "
    cp_group "$gname" "$gmem"
  done

  printf 'New password for all authorized users except you (blank = skip): ' >&2
  stty -echo 2>/dev/null; read -r pw; stty echo 2>/dev/null; echo >&2
  for u in $AUTH; do
    id "$u" >/dev/null 2>&1 || continue
    if [ -n "$pw" ] && [ "$u" != "$ME" ]; then printf '%s\n' "$pw" | pw usermod -n "$u" -h 0 && log "password set: $u"; fi
    pw usermod -n "$u" -p +90d
  done
  log "passwords of authorized users expire in 90 days"
  prompt chg "Accounts that must change password at next login (space-separated, blank = none): "
  for u in $chg; do id "$u" >/dev/null 2>&1 && pw usermod -n "$u" -p 01-Jan-2000 && log "must change password: $u"; done
  if awk -F: '$1=="root" && $2=="" {f=1} END {exit !f}' /etc/master.passwd; then
    echo "root has no password, so any wheel member can su without one."
    ask "Set a root password now?" && passwd root
  fi
}

step_sudo() {
  hdr "sudo and doas"
  local s=/usr/local/etc/sudoers d=/usr/local/etc/doas.conf bak=/root/sudoers-backup.tgz
  if [ -f $s ]; then
    tar czf $bak $s /usr/local/etc/sudoers.d 2>/dev/null
    echo "Risky sudoers lines: NOPASSWD, !authenticate, Defaults with '!', rules for single users (should be %wheel only):"
    review_lines "$(grep -nHsE 'NOPASSWD|!authenticate|^[[:space:]]*Defaults[^[:space:]]*[[:space:]].*![a-z_]|^[[:space:]]*[a-z_][a-z0-9_-]*[[:space:]]+[^=]+=' \
        $s /usr/local/etc/sudoers.d/* | grep -vE '^[^:]+:[0-9]+:[[:space:]]*root[[:space:]]')"
    hdr "sudoers.d files not from any package"
    review_files "$(find /usr/local/etc/sudoers.d -type f 2>/dev/null | unowned)"
    if ! grep -rqs use_pty $s /usr/local/etc/sudoers.d; then
      mkdir -p /usr/local/etc/sudoers.d
      echo 'Defaults use_pty' > /usr/local/etc/sudoers.d/99-cp && chmod 440 /usr/local/etc/sudoers.d/99-cp && log "sudo: use_pty"
    fi
    chown root:wheel $s && chmod 440 $s
    if ! visudo -c >/dev/null; then
      echo "sudoers no longer parses. Restoring the backup."
      rm -f /usr/local/etc/sudoers.d/99-cp; tar xzf $bak -C / && log "restored sudoers from $bak"
    fi
  fi
  if [ -f $d ]; then
    echo "doas rules (nopass, and rules for single users instead of :wheel, are risky):"
    review_lines "$(grep -nHE 'nopass|^[[:space:]]*permit[[:space:]]+([a-z]+[[:space:]]+)*[a-z_][a-z0-9_-]*([[:space:]]|$)' $d |
      grep -vE 'permit[[:space:]]+(persist[[:space:]]+|keepenv[[:space:]]+)*:wheel')"
    doas -C $d && chmod 600 $d
  fi
  [ -f $s ] || [ -f $d ] || echo "Neither sudo nor doas is set up: admins use su, which needs the wheel group and the root password."
}

login_conf_set() {
  local f=/etc/login.conf k=$1 v=$2
  awk -v k="$k" -v v="$v" '
    FNR == NR {
      if ($0 ~ /^default:\\$/) b = 1
      else if (b) { if ($0 ~ "(^|:)" k "[=#@]") found = 1; if ($0 !~ /\\$/) b = 0 }
      next
    }
    /^default:\\$/ { print; if (!found) print "\t:" k "=" v ":\\"; b = 1; next }
    b { if ($0 ~ "(^|:)" k "[=#@]") gsub(":" k "[=#@][^:]*:", ":" k "=" v ":"); if ($0 !~ /\\$/) b = 0 }
    { print }' "$f" "$f" > "$f.cp" && cat "$f.cp" > "$f" && rm -f "$f.cp"
  log "$f default class: $k=$v"
}

step_passwords() {
  hdr "Password policy (login.conf, PAM)"
  local f u
  cp -p /etc/login.conf /etc/login.conf.bak
  login_conf_set passwd_format sha512
  login_conf_set minpasswordlen 12
  login_conf_set passwordtime 90d
  if cap_mkdb /etc/login.conf; then log "login.conf rebuilt"
  else echo "login.conf broke, restoring it."; cp -p /etc/login.conf.bak /etc/login.conf; cap_mkdb /etc/login.conf; fi

  f=/etc/pam.d/passwd
  if ls /usr/lib/pam_passwdqc.so* >/dev/null 2>&1 && [ -f $f ]; then
    grep -v 'pam_passwdqc' $f | awk '
      /^password[ \t]/ && !d { print "password\trequisite\tpam_passwdqc.so\tmin=disabled,disabled,disabled,12,12 similar=deny retry=3 enforce=users"; d = 1 }
      { print }' > $f.cp && cat $f.cp > $f && rm -f $f.cp
    log "PAM: passwdqc, 12+ characters using 3 kinds of characters"
  fi
  for f in $(grep -lE '[[:space:]]nullok' /etc/pam.d/* 2>/dev/null); do
    sed -i '' -E 's/[[:space:]]+nullok//' "$f" && log "PAM: nullok removed from $f"
  done
  for u in $(awk -F: '$2=="" {print $1}' /etc/master.passwd); do
    case $u in
      "$ME"|root) echo "$u has no password: set one with 'passwd $u'." ;;
      *) ask "Account '$u' has no password. Lock it?" && pw lock "$u" && log "locked empty-password account: $u" ;;
    esac
  done
  echo "FreeBSD has no account lockout module in base; the SSH hardening limits tries per connection (MaxAuthTries 3)."
  echo "Test now: in a new terminal log in as ${ME:-yourself} and run 'su -'. Keep this root shell open until that works."
}

step_login() {
  hdr "Console and login screen: no autologin, root password for single-user mode"
  local f
  if grep -qE '^console[[:space:]].*[[:space:]]secure' /etc/ttys; then
    sed -i '' -E 's/^(console[[:space:]].*[[:space:]])secure/\1insecure/' /etc/ttys && log "/etc/ttys: console insecure (single-user mode asks for the root password)"
  fi
  if grep -nE '^[^#]*getty[[:space:]]+(al\.|autologin)' /etc/ttys; then
    if ask "These terminals log someone in automatically. Switch them to the normal login prompt?"; then
      sed -i '' -E '/^[^#]/s/getty[[:space:]]+(al\.|autologin)([A-Za-z0-9.]*)/getty Pc/' /etc/ttys && kill -HUP 1 && log "/etc/ttys: autologin removed"
    fi
  fi
  f=$(awk '/^[^#[:space:]]/ {n = $0; sub(/[|:].*/, "", n)} /^[^#].*:al=/ && n !~ /^(al\.|autologin)/ {print n}' /etc/gettytab | sort -u | xargs)
  if [ -n "$f" ]; then
    echo "gettytab entries that log a user in automatically: $f"
    if ask "Remove the al= part from them?"; then
      awk '/^[^#[:space:]]/ {n = $0; sub(/[|:].*/, "", n)} /^[^#]/ && n !~ /^(al\.|autologin)/ {gsub(/:al=[^:]*/, "")} {print}' /etc/gettytab > /etc/gettytab.cp &&
        cat /etc/gettytab.cp > /etc/gettytab && rm -f /etc/gettytab.cp && log "/etc/gettytab: al= removed from $f"
    fi
  fi
  for f in /usr/local/etc/lightdm/lightdm.conf /usr/local/etc/lightdm/lightdm.conf.d/*.conf; do
    [ -f "$f" ] || continue
    sed -i '' -E 's/^allow-guest=.*/allow-guest=false/; s/^(autologin-user.*)/#\1/' "$f" && log "lightdm: guest off, autologin commented out in $f"
  done
  for f in /usr/local/etc/sddm.conf /usr/local/etc/sddm.conf.d/*.conf; do
    [ -f "$f" ] && grep -qE '^[[:space:]]*User=' "$f" || continue
    sed -i '' -E 's/^([[:space:]]*User=)/#\1/' "$f" && log "sddm: autologin commented out in $f"
  done
  f=/usr/local/etc/slim.conf
  if [ -f $f ]; then
    set_kv $f auto_login no
    sed -i '' -E 's/^(default_user[[:space:]])/#\1/' $f
  fi
  f=/usr/local/etc/gdm/custom.conf
  if [ -f $f ]; then
    sed -i '' -E 's/^[[:space:]]*(AutomaticLoginEnable|TimedLoginEnable)[[:space:]]*=.*/\1=false/' $f && log "gdm: automatic login off"
  fi
}

allow_port() {
  [ "$(sysrc -n pf_enable 2>/dev/null)" = YES ] && [ -f /etc/pf.conf ] || return 0
  grep -qE "proto $1 to port $2( |$)" /etc/pf.conf && return 0
  echo "pass in quick proto $1 to port $2 ${3:+flags $3 }keep state" >> /etc/pf.conf
  pfctl -f /etc/pf.conf && log "pf: allowed $1 port $2"
}

step_firewall() {
  local a
  hdr "Firewall (pf)"
  if [ "$(sysrc -n firewall_enable 2>/dev/null)" = YES ]; then
    echo "ipfw is already on (firewall_type=$(sysrc -n firewall_type 2>/dev/null)):"
    ipfw list 2>/dev/null | head -n 30
    ask "Keep ipfw instead of switching to pf?" && return
    rc_set firewall_enable=NO
    service ipfw stop
  fi
  if [ -s /etc/pf.conf ]; then
    echo "Current /etc/pf.conf:"; cat /etc/pf.conf
    if ! ask "Replace it with a simple ruleset (block everything coming in, allow going out)? Old copy kept as /etc/pf.conf.bak"; then
      kldload -n pf 2>/dev/null
      pfctl -nf /etc/pf.conf && rc_set pf_enable=YES pflog_enable=YES && service pf restart && service pflog restart
      return
    fi
    cp /etc/pf.conf /etc/pf.conf.bak
  fi
  kldload -n pf 2>/dev/null
  printf '%s\n' 'set skip on lo0' 'block in log all' 'pass out all keep state' 'pass quick inet6 proto icmp6 all' > /etc/pf.conf
  if sockstat -46l | awk '$2=="sshd"' | grep -q .; then
    if sockstat -46c 2>/dev/null | awk '$2 ~ /^sshd/ && $6 ~ /:22$/' | grep -q .; then
      echo "Someone is logged in over SSH right now, so SSH stays allowed (the services step can still turn sshd off)."
      a=y
    elif readme_service_text "$(readme_text 2>/dev/null)" | grep -qiE '(^|[^a-z])ssh'; then
      prompt a "sshd is running and the README mentions SSH. Let SSH in? [Y/n] "
      a=${a:-y}
    else
      prompt a "sshd is running. Let SSH in? (only if the README needs it) [y/N] "
    fi
    case $a in [yY]*) echo 'pass in quick proto tcp to port 22 flags any keep state' >> /etc/pf.conf ;; esac
  fi
  if ! pfctl -nf /etc/pf.conf; then echo "pf.conf has errors, not turning pf on."; return; fi
  rc_set pf_enable=YES pflog_enable=YES
  if pfctl -s info >/dev/null 2>&1; then pfctl -f /etc/pf.conf; else service pf start; fi
  pfctl -e 2>/dev/null
  service pflog start >/dev/null 2>&1
  log "pf on: incoming blocked, outgoing allowed"
  pfctl -sr
  echo "Services kept in the services step open their own ports."
}

SYSCTLS='security.bsd.see_other_uids=0 security.bsd.see_other_gids=0 security.bsd.see_jail_proc=0
security.bsd.unprivileged_read_msgbuf=0 security.bsd.unprivileged_proc_debug=0 security.bsd.hardlink_check_uid=1
security.bsd.hardlink_check_gid=1 kern.randompid=1 kern.sugid_coredump=0 kern.elf64.aslr.enable=1
kern.elf32.aslr.enable=1 kern.vt.kbd_reboot=0 net.inet.tcp.blackhole=2 net.inet.udp.blackhole=1
net.inet.tcp.drop_synfin=1 net.inet.icmp.drop_redirect=1 net.inet6.icmp6.rediraccept=0 net.inet.ip.redirect=0
net.inet6.ip6.redirect=0 net.inet.ip.forwarding=0 net.inet6.ip6.forwarding=0 net.inet.ip.sourceroute=0
net.inet.ip.accept_sourceroute=0 net.inet.icmp.bmcastecho=0'

step_kernel() {
  hdr "sysctl, rc.conf and loader.conf hardening, file permissions"
  local kv f
  [ -f /etc/sysctl.conf ] || : > /etc/sysctl.conf
  for kv in $SYSCTLS; do
    sysctl -n "${kv%%=*}" >/dev/null 2>&1 || continue
    set_kv /etc/sysctl.conf "${kv%%=*}" "${kv#*=}" =
    sysctl "$kv" >/dev/null 2>&1 || echo "  ${kv%%=*} applies after a reboot"
  done
  rc_set clear_tmp_enable=YES
  rc_set syslogd_flags=-ss
  service syslogd restart >/dev/null 2>&1
  rc_set sendmail_enable=NONE
  rc_set dumpdev=NO
  rc_set gateway_enable=NO ipv6_gateway_enable=NO
  [ -f /boot/loader.conf ] || : > /boot/loader.conf
  set_kv /boot/loader.conf security.bsd.allow_destructive_dtrace '"0"' =
  chown root:wheel /etc/master.passwd /etc/spwd.db /etc/passwd /etc/pwd.db /etc/group
  chmod 600 /etc/master.passwd /etc/spwd.db
  chmod 644 /etc/passwd /etc/pwd.db /etc/group
  [ -f /usr/local/etc/sudoers ] && chmod 440 /usr/local/etc/sudoers
  [ -f /usr/local/etc/doas.conf ] && chmod 600 /usr/local/etc/doas.conf
  chmod 1777 /tmp /var/tmp
  log "fixed master.passwd/passwd/group/sudoers/tmp perms"
}

step_misc() {
  hdr "auditd, home folders, files with no owner"
  local d
  rc_set auditd_enable=YES
  service auditd start >/dev/null 2>&1 || service auditd restart >/dev/null 2>&1
  service auditd status >/dev/null 2>&1 && log "auditd on"
  for d in /home/*/; do [ -d "$d" ] && chmod 750 "$d"; done
  chmod 700 /root
  log "home folders 750, /root 700"
  hdr "Files with no owner or group (planted or left over)"
  find / -xdev \( -nouser -o -nogroup \) 2>/dev/null | head -n 30
}

BAD_PKGS='john hydra nmap zenmap wireshark wireshark-lite aircrack-ng ettercap kismet dsniff nikto sqlmap medusa
fcrackzip hashcat ophcrack yersinia p0f masscan zmap netcat ncat socat pdfcrack rarcrack crunch cewl ncrack hping3
dirb gobuster wfuzz skipfish bettercap driftnet arp-scan nbtscan x11vnc tightvnc tigervnc-server xrdp
freebsd-telnetd qbittorrent qbittorrent-nox transmission transmission-gtk transmission-qt transmission-daemon
transmission-cli deluge rtorrent amule nicotine-plus yt-dlp youtube_dl freeciv wesnoth supertux supertuxkart 0ad
openarena minetest luanti ninvaders nethack36 nethack34 angband crawl bsdgames frozen-bubble neverball pingus
extremetuxracer openttd xmoto aisleriot gnome-mines gnome-chess gnome-sudoku kpat kmines kmahjongg ksudoku'

pkg_remove() {
  local p=$1 extra
  extra=$(pkg delete -n "$p" 2>/dev/null | awk '/to be REMOVED/ {on=1; next} on && /^[ \t]+[^ \t]/ {sub(/^[ \t]+/, ""); sub(/:.*/, ""); print}' |
    grep -vxF "$p" | xargs)
  if [ -n "$extra" ]; then
    echo "  Removing $p also removes: $extra"
    ask "  Remove $p and those?" || return 1
  fi
  pkg delete -y "$p" >/dev/null && log "removed package $p${extra:+ (also removed: $extra)}"
}

step_packages() {
  local p n list
  if ! have_pkg; then echo "pkg is not set up, so no packages are installed."; return; fi
  hdr "Packages installed on purpose, newest first. Skip anything the README needs."
  pkg query -e '%a = 0' '%t %n %c' | sort -rn | grep -vE '^[0-9]+ (pkg|FreeBSD-[^ ]*) ' | awk '{ $1 = ""; sub(/^ /, ""); print }' > "$TMPD/manual"
  awk '{ printf "%3d. %s\n", NR, $0 }' "$TMPD/manual"
  prompt list "Numbers to remove (space-separated, Enter = none): "
  for n in $list; do
    case $n in *[!0-9]*) continue ;; esac
    p=$(sed -n "${n}p" "$TMPD/manual" | awk '{print $1}')
    [ -n "$p" ] && pkg_installed "$p" && pkg_remove "$p"
  done
  hdr "Known prohibited software"
  for p in $BAD_PKGS; do
    pkg_installed "$p" || continue
    ask "Remove $p?" && pkg_remove "$p"
  done
  hdr "Packages nothing needs any more (pkg autoremove)"
  list=$(pkg autoremove -n 2>/dev/null | awk '/to be REMOVED/ {on=1; next} on && /^[ \t]+[^ \t]/ {sub(/^[ \t]+/, ""); sub(/:.*/, ""); print}' | xargs)
  if [ -n "$list" ]; then
    echo "  $list"
    ask "Remove them? (say no if desktop programs are in the list)" && pkg autoremove -y >/dev/null && log "autoremove: $list"
  else
    echo "  none"
  fi
}

harden_ssh() {
  local f=/etc/ssh/sshd_config
  set_kv $f PermitRootLogin no
  set_kv $f PermitEmptyPasswords no
  set_kv $f X11Forwarding no
  set_kv $f MaxAuthTries 3
  set_kv $f LoginGraceTime 60
  set_kv $f HostbasedAuthentication no
  set_kv $f IgnoreRhosts yes
  set_kv $f UsePAM yes
  if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' $f; then
    mkdir -p /etc/ssh/sshd_config.d
    printf '%s\n' 'PermitRootLogin no' 'PermitEmptyPasswords no' 'X11Forwarding no' 'MaxAuthTries 3' 'LoginGraceTime 60' \
      'HostbasedAuthentication no' 'IgnoreRhosts yes' 'UsePAM yes' > /etc/ssh/sshd_config.d/00-cp.conf && log "wrote /etc/ssh/sshd_config.d/00-cp.conf"
  fi
  sshd -t && service sshd restart
  allow_port tcp 22
}

harden_ftpd() {
  local u
  if id ftp >/dev/null 2>&1; then
    ask "The 'ftp' account turns on anonymous FTP. Delete it?" && pw userdel -n ftp && log "deleted ftp account (anonymous FTP off)"
  fi
  for u in root toor; do grep -qx "$u" /etc/ftpusers || { echo "$u" >> /etc/ftpusers; log "/etc/ftpusers: $u"; }; done
  allow_port tcp 21
}

harden_vsftpd() {
  local f=/usr/local/etc/vsftpd.conf
  set_kv $f anonymous_enable NO =
  set_kv $f anon_upload_enable NO =
  set_kv $f anon_mkdir_write_enable NO =
  set_kv $f local_enable YES =
  set_kv $f chroot_local_user YES =
  set_kv $f xferlog_enable YES =
  service vsftpd restart
  allow_port tcp 21
}

harden_php() {
  local f=/usr/local/etc/php.ini
  [ -f $f ] || { [ -f $f-production ] && cp $f-production $f && log "php.ini from php.ini-production"; }
  [ -f $f ] || return 0
  set_kv $f expose_php Off ' = '
  set_kv $f display_errors Off ' = '
  set_kv $f allow_url_include Off ' = '
  set_kv $f allow_url_fopen Off ' = '
  set_kv $f disable_functions exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec ' = '
  service php_fpm status >/dev/null 2>&1 && service php_fpm restart
  service php-fpm status >/dev/null 2>&1 && service php-fpm restart
}

harden_apache() {
  local f=/usr/local/etc/apache24/httpd.conf
  set_kv $f ServerTokens Prod
  set_kv $f ServerSignature Off
  set_kv $f TraceEnable Off
  for f in /usr/local/etc/apache24/httpd.conf /usr/local/etc/apache24/Includes/*.conf /usr/local/etc/apache24/extra/*.conf; do
    [ -f "$f" ] || continue
    sed -i '' -E 's/^([[:space:]]*Options[^#]*)[[:space:]]\+?Indexes([[:space:]]|$)/\1\2/; s/^([[:space:]]*Options)[[:space:]]*$/\1 None/' "$f"
  done
  log "apache: Indexes removed"
  harden_php
  if apachectl configtest; then service apache24 restart; else echo "apache config test failed, check above."; fi
  allow_port tcp 80; allow_port tcp 443
}

harden_nginx() {
  local f=/usr/local/etc/nginx/nginx.conf
  if grep -q server_tokens $f; then
    sed -i '' -E 's/^([[:space:]]*)#?[[:space:]]*server_tokens.*/\1server_tokens off;/' $f
  else
    sed -i '' -E 's/^([[:space:]]*http[[:space:]]*\{)/\1 server_tokens off;/' $f
  fi
  sed -i '' -E 's/autoindex[[:space:]]+on/autoindex off/' $f /usr/local/etc/nginx/conf.d/*.conf 2>/dev/null
  log "nginx: server_tokens off, autoindex off"
  harden_php
  if nginx -t; then service nginx reload; else echo "nginx config test failed, check above."; fi
  allow_port tcp 80; allow_port tcp 443
}

harden_samba() {
  local f=/usr/local/etc/smb4.conf
  ini_set $f global 'map to guest' never
  ini_set $f global 'restrict anonymous' 2
  ini_set $f global 'usershare allow guests' no
  ini_set $f global 'server min protocol' SMB2
  ini_set $f global 'smb encrypt' required
  sed -i '' -E 's/^([[:space:]]*)([Gg]uest ok|[Pp]ublic)[[:space:]]*=[[:space:]]*yes/\1\2 = no/' $f
  log "smb4.conf: guest shares off"
  if testparm -s >/dev/null 2>&1; then service samba_server restart; else echo "testparm failed, check $f."; fi
  allow_port tcp 445; allow_port tcp 139
}

harden_mysql() {
  local f
  for f in /usr/local/etc/mysql/my.cnf /usr/local/etc/my.cnf; do
    [ -f $f ] || continue
    ask "Only allow local database connections (bind-address 127.0.0.1)?" && ini_set $f mysqld bind-address 127.0.0.1
    ini_set $f mysqld local-infile 0
  done
  if mysql -uroot -e 'SELECT user, host FROM mysql.user;'; then
    ask "Delete anonymous users, remote root logins and the test database?" &&
      mysql -uroot -e "DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'); DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" &&
      log "mysql: removed anonymous users, remote root, test db"
  else
    echo "Could not log in as database root. Check users by hand: mysql -u root -p"
  fi
  service mysql-server restart
}

harden_inetd() {
  echo "Services inetd starts (telnet, ftp, tftp and the r-commands are unsafe):"
  review_lines "$(grep -nHvE '^[[:space:]]*(#|$)' /etc/inetd.conf)"
  service inetd restart
}

SVC_LIST='sshd|ssh
inetd|inetd|telnet|tftp|rlogin|rsh
ftpd|(^|[^a-z])ftp
rpcbind|rpc|nfs|(^|[^a-z])nis([^a-z]|$)
nfsd|nfs
mountd|nfs
lpd|print|lpd
bsnmpd|snmp
snmpd|snmp
ypserv|(^|[^a-z])nis([^a-z]|$)
rwhod|rwho
routed|routing|routed
ctld|iscsi
apache24|apache|httpd|web ?server|website|wordpress|php
nginx|nginx|web ?server|website|wordpress|php
php_fpm|php|wordpress
php-fpm|php|wordpress
mysql-server|mysql|mariadb|database|wordpress
postgresql|postgres|database
samba_server|samba|(^|[^a-z])smb|file shar
vsftpd|vsftpd|(^|[^a-z])ftp
proftpd|proftpd|(^|[^a-z])ftp
pure-ftpd|pure-?ftpd|(^|[^a-z])ftp
named|bind|(^|[^a-z])dns
unbound|unbound|(^|[^a-z])dns
dhcpd|dhcp
cupsd|cups|print
avahi-daemon|avahi|mdns|bonjour|zeroconf
squid|squid|proxy
postfix|postfix|mail|smtp
dovecot|dovecot|mail|imap|pop3
sendmail|sendmail|mail server|smtp
xrdp|xrdp|remote desktop
openvpn|vpn
redis|redis
memcached|memcached
mongod|mongo'

svc_keep() {
  case $1 in
    sshd) harden_ssh ;;
    ftpd) harden_ftpd ;;
    vsftpd) harden_vsftpd ;;
    proftpd|pure-ftpd) allow_port tcp 21; echo "Turn off anonymous login in its config by hand." ;;
    apache24) harden_apache ;;
    nginx) harden_nginx ;;
    php_fpm|php-fpm) harden_php ;;
    samba_server) harden_samba ;;
    mysql-server) harden_mysql ;;
    inetd) harden_inetd ;;
    named|unbound) allow_port tcp 53; allow_port udp 53 ;;
    postfix|sendmail) allow_port tcp 25 ;;
    dovecot) allow_port tcp 143; allow_port tcp 993 ;;
    cupsd) allow_port tcp 631 ;;
    nfsd|mountd|rpcbind) allow_port tcp 111; allow_port udp 111; allow_port tcp 2049; allow_port udp 2049 ;;
    *) echo "No auto-hardening for $1, check its config by hand." ;;
  esac
}

step_services() {
  hdr "Services: keep only what the README needs"
  local text src line s re def a rcvar p enabled
  text=$(readme_text)
  src=$(readme_service_text "$text")
  if [ -z "$text" ]; then echo "README not found: no defaults, decide each one."
  elif [ "$src" != "$text" ]; then printf 'README critical services:\n%s\n\n' "$src"
  else echo "README has no 'Critical Services' section: matching against the whole README, double-check each."; fi
  enabled=$(service -e | sed 's#.*/##')
  printf '%s\n' "$SVC_LIST" > "$TMPD/svcs"
  while IFS= read -r line <&3; do
    s=${line%%|*} re=${line#*|}
    if ! in_list "$s" $enabled; then
      [ -n "$text" ] && printf '%s\n' "$src" | grep -qiE "$re" && [ -e "/etc/rc.d/$s" -o -e "/usr/local/etc/rc.d/$s" ] &&
        echo "README seems to name $s but it is not enabled. If it needs it: sysrc $(service "$s" rcvar 2>/dev/null | sed -nE 's/^([A-Za-z0-9_]+_enable)=.*/\1/p' | head -n1)=YES && service $s start"
      continue
    fi
    def=''
    if [ -n "$text" ]; then
      if printf '%s\n' "$src" | grep -qiE "$re"; then def=k; echo "$s: README seems to need it, keep and harden."
      else def=d; echo "$s: not in README, disable."; fi
    fi
    p=''
    [ -e "/usr/local/etc/rc.d/$s" ] && p=$(pkg which -q "/usr/local/etc/rc.d/$s" 2>/dev/null)
    prompt a "$s: (k)eep/harden, (d)isable${p:+, (r)emove package $p}, (s)kip? [$def] "
    a=${a:-$def}
    case $a in
      k*) svc_keep "$s"; log "kept $s" ;;
      d*|r*)
        rcvar=$(service "$s" rcvar 2>/dev/null | sed -nE 's/^([A-Za-z0-9_]+_enable)=.*/\1/p' | head -n1)
        service "$s" onestop >/dev/null 2>&1
        [ -n "$rcvar" ] && rc_set "$rcvar=NO"
        log "disabled $s"
        case $a in r*) [ -n "$p" ] && pkg_remove "${p%-*}" ;; esac ;;
    esac
  done 3< "$TMPD/svcs"
}

FF_PREFS='browser.safebrowsing.malware.enabled=true browser.safebrowsing.phishing.enabled=true
browser.safebrowsing.downloads.enabled=true browser.safebrowsing.downloads.remote.block_potentially_unwanted=true
browser.safebrowsing.downloads.remote.block_uncommon=true dom.disable_open_during_load=true
xpinstall.whitelist.required=true signon.rememberSignons=false dom.security.https_only_mode=true'

ff_policy() {
  local kv sep='' prefs=''
  for kv in $FF_PREFS; do
    prefs="$prefs$sep\"${kv%%=*}\": {\"Value\": ${kv#*=}, \"Status\": \"locked\"}"
    sep=',
      '
  done
  cat <<EOF
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "PopupBlocking": {"Default": true, "Locked": true},
    "OfferToSaveLogins": false,
    "EnableTrackingProtection": {"Value": true, "Locked": true, "Cryptomining": true, "Fingerprinting": true},
    "HttpsOnlyMode": "force_enabled",
    "Preferences": {
      $prefs
    }
  }
}
EOF
}

CHROME_POLICY='{
  "SafeBrowsingProtectionLevel": 1,
  "SafeBrowsingEnabled": true,
  "PasswordLeakDetectionEnabled": true,
  "DefaultPopupsSetting": 2,
  "DownloadRestrictions": 1,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "BlockThirdPartyCookies": true,
  "HttpsOnlyMode": "force_enabled"
}'

step_browsers() {
  hdr "Browsers (close Firefox and Chromium first)"
  local d f p kv
  pgrep -x 'firefox|chrome|chromium' >/dev/null && echo "A browser is still running. Close it, or it may overwrite profile settings."
  if [ -x /usr/local/bin/chrome ] || [ -x /usr/local/bin/chromium ] || [ -d /usr/local/etc/chromium ]; then
    echo "Existing Chromium policy files (planted ones can turn off Safe Browsing or force-install extensions):"
    review_files "$(find /usr/local/etc/chromium -path '*policies*' -name '*.json' ! -name cp.json 2>/dev/null)"
    d=/usr/local/etc/chromium/policies/managed
    mkdir -p $d && echo "$CHROME_POLICY" > $d/cp.json && chmod 644 $d/cp.json && log "wrote $d/cp.json"
    echo "Check chrome://policy shows them."
  fi
  for d in /usr/local/lib/firefox*/; do
    [ -d "$d" ] || continue
    f=${d}distribution/policies.json
    mkdir -p "${d}distribution"
    [ -s "$f" ] && { echo "--- old $f"; cat "$f"; cp -p "$f" "$f.bak"; }
    ff_policy > "$f" && chmod 644 "$f" && log "wrote $f"
  done
  for p in /home/*/.mozilla/firefox/*/ /root/.mozilla/firefox/*/; do
    [ -f "${p}prefs.js" ] || continue
    [ -s "${p}user.js" ] && { echo "--- old ${p}user.js"; cat "${p}user.js"; }
    for kv in $FF_PREFS; do echo "user_pref(\"${kv%%=*}\", ${kv#*=});"; done > "${p}user.js"
    chown "$(stat -f %Su "$p"):$(stat -f %Sg "$p")" "${p}user.js" && log "wrote ${p}user.js"
  done
  ls -d /usr/local/lib/firefox*/ >/dev/null 2>&1 && echo "Check about:policies shows them."
}

SUS='(^|[^a-z0-9_])(nc|ncat|netcat|socat|telnet)([^a-z0-9_]|$)|/dev/(tcp|udp)/|bash -i|sh -i|mkfifo|python[0-9.]* -c|perl -e|php -r|ruby -e|base64 -d|b64decode|curl |wget |fetch |\| *(ba)?sh([^a-z]|$)|chmod [0-7+]*s|LD_PRELOAD'
STRONG='/dev/(tcp|udp)/|bash -i|sh -i *[>&]|mkfifo [^ ;]+ *(;|&&|\|)|(^|[^a-z])nc(at)? .*-[ec] |socat .*exec|pty\.spawn|os\.dup2|fsockopen|eval\(\$_|shell_exec\(|passthru\('
GTFO='^(bash|sh|csh|tcsh|ksh|dash|zsh|busybox|find|vi|vim|nvi|ee|nano|ed|less|more|python[0-9.]*|perl[0-9.]*|ruby|php[0-9.]*|lua.*|node|cp|mv|tee|dd|cat|b64decode|base64|xxd|env|awk|nawk|gawk|sed|tar|bsdtar|zip|nmap|nc|socat|fetch|wget|curl|gdb|truss|chmod|chown|rsync|git|make|expect|tclsh.*)$'

step_backdoors() {
  local f line name pid exe u

  hdr "Cron: suspicious lines + every user crontab entry"
  review_lines "$(grep -nHsE "$SUS" /etc/crontab /etc/cron.d/* /usr/local/etc/cron.d/* /var/cron/tabs/*
                  grep -nHsvE '^[[:space:]]*(#|$)|^[A-Z_]+=' /var/cron/tabs/*)"
  hdr "Cron files not from any package"
  review_files "$(find /etc/cron.d /usr/local/etc/cron.d -type f ! -path /etc/cron.d/at 2>/dev/null | unowned)"
  hdr "at jobs (remove with atrm <id>)"
  atq 2>/dev/null

  hdr "rc scripts and startup settings: suspicious lines"
  review_lines "$(grep -nHsE "$SUS" /etc/rc.local /etc/rc.conf /etc/rc.conf.local /etc/rc.conf.d/* /etc/periodic.conf /etc/periodic.conf.local
                  grep -nHsE "$STRONG" /etc/rc.d/* /etc/periodic/*/*)"
  hdr "rc.local commands"
  review_lines "$(grep -nHsvE '^[[:space:]]*(#|$|exit 0)' /etc/rc.local)"
  hdr "rc.d scripts and periodic jobs not from any package"
  review_files "$(find /usr/local/etc/rc.d /usr/local/etc/periodic -type f 2>/dev/null | unowned)"

  hdr "Shell startup files and autostart: suspicious lines"
  review_lines "$(grep -nHsE "$SUS|alias +(sudo|su|passwd|pkg|cat|ls)[ =]|PROMPT_COMMAND|trap " \
    /etc/profile /etc/csh.cshrc /etc/csh.login /etc/csh.logout /etc/profile.d/* /usr/local/etc/profile.d/* \
    /root/.profile /root/.shrc /root/.cshrc /root/.login /root/.bashrc /root/.bash_profile \
    /home/*/.profile /home/*/.shrc /home/*/.cshrc /home/*/.login /home/*/.bashrc /home/*/.bash_profile \
    /home/*/.xinitrc /home/*/.xsession /usr/local/etc/xdg/autostart/*.desktop /home/*/.config/autostart/*.desktop)"
  hdr "Autostart entries not from any package"
  review_files "$( { find /usr/local/etc/xdg/autostart -type f 2>/dev/null | unowned; ls -d /home/*/.config/autostart/* /root/.config/autostart/* 2>/dev/null; } )"

  hdr "PAM backdoors (pam_exec, sufficient pam_permit)"
  review_lines "$(grep -nHsE 'pam_exec|sufficient[[:space:]]+pam_permit' /etc/pam.d/* /usr/local/etc/pam.d/*)"
  hdr "Library redirects (libmap) and LD_PRELOAD"
  review_lines "$(grep -nHsvE '^[[:space:]]*(#|$)|^includedir[[:space:]]+/usr/local/etc/libmap\.d' /etc/libmap.conf)"
  review_files "$(find /usr/local/etc/libmap.d -type f 2>/dev/null | unowned)"
  grep -nHsE 'LD_PRELOAD|LD_LIBRARY_PATH' /etc/login.conf && echo "^ fix that by hand in /etc/login.conf, then run: cap_mkdb /etc/login.conf"
  hdr "Kernel modules loaded at boot"
  review_lines "$(grep -nHsE '_load=|_name=|module_path|preload' /boot/loader.conf /boot/loader.conf.local /boot/loader.conf.d/*.conf)"
  [ -n "$(sysrc -n kld_list 2>/dev/null)" ] && echo "rc.conf kld_list: $(sysrc -n kld_list)"
  hdr "SSH authorized_keys"
  for f in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys*; do
    [ -s "$f" ] || continue
    echo "--- $f"; awk '{print $1, $NF}' "$f"
    ask "  Delete $f?" && rm -f -- "$f" && log "deleted $f"
  done

  hdr "SUID/SGID: shell-capable, outside system folders, or from no package"
  find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null > "$TMPD/suid"
  unowned < "$TMPD/suid" > "$TMPD/suid.unowned"
  while IFS= read -r f <&3; do
    case $f in
      /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/libexec/*|/libexec/*|/usr/lib/*|/lib/*|/usr/tests/*)
        printf '%s\n' "${f##*/}" | grep -qE "$GTFO" || continue ;;
      /usr/local/*)
        printf '%s\n' "${f##*/}" | grep -qE "$GTFO" || grep -qxF "$f" "$TMPD/suid.unowned" || continue ;;
    esac
    ls -l "$f"
    ask "  Remove SUID/SGID from $f?" && chmod u-s,g-s "$f" && log "chmod u-s,g-s $f"
  done 3< "$TMPD/suid"

  hdr "Programs in /usr/local/bin and /usr/local/sbin not from any package"
  review_files "$(find /usr/local/bin /usr/local/sbin -type f 2>/dev/null | unowned)"
  hdr "Files containing reverse-shell / webshell code"
  review_files "$(grep -rlIsE "$STRONG" --exclude-dir=.cache --exclude-dir=.mozilla /home /root /usr/local/www /srv /tmp /var/tmp 2>/dev/null |
    grep -v "^$TMPD/" | grep -vxF "$(realpath "$0" 2>/dev/null)")"
  hdr "Reverse-shell / webshell code in /etc and /usr/local/etc"
  review_lines "$(grep -rnHIsE "$STRONG" /etc /usr/local/etc 2>/dev/null)"
  hdr "Executable or hidden files in temp folders"
  find /tmp /var/tmp -mindepth 1 \( -name '.*' -o \( -type f -perm -u+x \) \) ! -name '.X*-unix' ! -name '.ICE-unix' \
    ! -name '.font-unix' ! -name '.XIM-unix' 2>/dev/null

  hdr "Suspicious listening processes"
  sockstat -46l | awk 'NR>1 && $3 ~ /^[0-9]+$/ {print $2, $3}' | sort -u > "$TMPD/listen"
  while read -r name pid <&3; do
    exe=$(procstat -b "$pid" 2>/dev/null | awk 'NR==2 {print $NF}')
    printf '%s\n' "$name" | grep -qE '^(nc|ncat|netcat|socat|python.*|perl.*|ruby|php.*|sh|bash|csh|tcsh|zsh|telnetd)$' ||
      case $exe in /tmp/*|/var/tmp/*|/home/*|/usr/home/*|/root/*) ;; *) continue ;; esac
    sockstat -46l -P tcp,udp 2>/dev/null | awk -v p="$pid" '$3==p'
    echo "  exe: $exe"
    echo "  cmd: $(ps -o args= -p "$pid")"
    ask "  Kill pid $pid?" && kill -9 "$pid" && log "killed $pid ($name)"
  done 3< "$TMPD/listen"
  hdr "Processes running from temp or home folders"
  procstat -b -a 2>/dev/null | awk 'NR>1 && $NF ~ /^\/(tmp|var\/tmp|home|usr\/home)\// {print $1, $NF}' > "$TMPD/tmpprocs"
  while read -r pid exe <&3; do
    echo "pid $pid: $exe :: $(ps -o args= -p "$pid")"
    ask "  Kill pid $pid?" && kill -9 "$pid" && log "killed $pid ($exe)"
  done 3< "$TMPD/tmpprocs"

  if pkg_installed FreeBSD-runtime; then
    echo "The base system is installed as packages, so the package check below covers base system files too."
  elif ask "Check base system files against FreeBSD's official hashes (freebsd-update IDS, needs internet, slow)?"; then
    freebsd-update IDS 2>&1 | grep -vE '^/etc/|^/root has|^/tmp has|^/var/tmp has|^Looking|^Fetching|^Inspecting|^Preparing|done\.$' | head -n 50
    echo "(changed files in /etc and folder permissions this script set are left out)"
  fi
  if have_pkg && ask "Check installed packages for changed files (pkg check -s)?"; then
    pkg check -s -a 2>&1 | grep -v '^Checking' | head -n 50
  fi
  echo "Killed something? Run this step again: if it comes back, its autostart is still somewhere."
}

step_media() {
  hdr "Media files"
  local list n
  list=$(find /home /root /usr/local/www /srv /tmp /var/tmp -type f \( -iname '*.mp3' -o -iname '*.mp4' \
    -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.flac' -o -iname '*.aac' \
    -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.flv' \) \
    ! -path '*CyberPatriot*' 2>/dev/null)
  [ -n "$list" ] || { echo "None found."; return; }
  printf '%s\n' "$list"
  n=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
  if ask "Delete all $n files above?"; then
    printf '%s\n' "$list" | while IFS= read -r f; do rm -f -- "$f"; done
    log "deleted $n media files"
  fi
}

step_files() {
  hdr "Files with passwords or personal data (prohibited on most images)"
  review_files "$( {
    find /home /root /srv /usr/local/www -xdev -type f \( -iname '*password*' -o -iname '*passwd*' -o -iname '*cred*' \
      -o -iname '*secret*' -o -iname '*.kdbx' -o -iname '*ssn*' -o -iname '*credit*' -o -iname '*customer*' \
      -o -iname '*.pcap' -o -iname '*.pcapng' \) ! -path '*/.mozilla/*' ! -path '*/.cache/*' ! -path '*/.config/*' 2>/dev/null
    grep -rlIsE '(^|[^0-9])[0-9]{3}-[0-9]{2}-[0-9]{4}([^0-9]|$)|(^|[^0-9])[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}([^0-9]|$)|passw(or)?d *[:=]' \
      --exclude-dir=.mozilla --exclude-dir=.cache --exclude-dir=.config --exclude-dir=.local /home /root /srv /usr/local/www 2>/dev/null
  } | grep -viE '/[^/]*readme[^/]*$' | grep -vxF "$(realpath "$0" 2>/dev/null)" | sort -u)"

  hdr "Programs disguised as documents, pictures or media (answer forensics questions about them first)"
  review_files "$(find /home /root /srv /usr/local/www -xdev -type f -size -200M ! -path '*CyberPatriot*' \
    \( -iname '*.pdf' -o -iname '*.doc*' -o -iname '*.xls*' -o -iname '*.ppt*' -o -iname '*.od[tsp]' -o -iname '*.txt' \
       -o -iname '*.csv' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.mp3' \
       -o -iname '*.mp4' -o -iname '*.zip' -o -iname '*.html' \) \
    -exec sh -c 'for f; do [ "$(head -c4 "$f" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] && echo "$f"; done' _ {} + 2>/dev/null)"
}

step_updates() {
  hdr "Updates (slow)"
  local p ver
  if ! have_pkg; then
    ask "pkg is not set up. Set it up now (needs internet)?" && env ASSUME_ALWAYS_YES=yes pkg bootstrap -f && log "pkg bootstrapped"
  fi
  if have_pkg; then
    for p in $(pkg lock -lq 2>/dev/null); do
      ask "$p is locked against updates. Unlock?" && pkg unlock -y "$p" && log "unlocked $p"
    done
  fi
  grep -E '^(ServerName|KeyPrint)' /etc/freebsd-update.conf
  echo "^ should be update.FreeBSD.org and 800651ef4b4c71c27e60786d7b487188970f4b4169cc055784e21eb71d410cc5"
  ver=$(freebsd-version -u)
  if have_pkg && pkg info -e FreeBSD-runtime 2>/dev/null; then
    echo "The base system is installed as packages (pkgbase): pkg upgrade below updates it too."
  else
    case $ver in
      *-RELEASE*)
        if ask "Install FreeBSD base system updates for $ver (freebsd-update)?"; then
          freebsd-update --not-running-from-cron fetch install && log "freebsd-update fetch install"
        fi ;;
      *) echo "$ver is not a RELEASE, freebsd-update does not apply." ;;
    esac
    if ! grep -qE '^[^#].*freebsd-update cron' /etc/crontab; then
      printf '@daily\t\t\t\troot\tfreebsd-update cron\n' >> /etc/crontab && log "crontab: daily freebsd-update cron (downloads updates)"
    fi
  fi
  if have_pkg && ask "Upgrade all packages (pkg upgrade)?"; then
    if pkg update -f; then
      pkg upgrade -y && log "pkg upgrade done"
    else
      echo "pkg update failed. A planted or broken repo does that: run the repos step, then this one again."
    fi
  fi
  if have_pkg; then
    hdr "Packages that still have known vulnerabilities"
    pkg audit -F 2>/dev/null | tail -n 20
  fi
  echo "If the kernel was updated, reboot: freebsd-version -k should then match freebsd-version -u."
}

STEPS='audit repos users sudo passwords login firewall kernel misc packages services browsers backdoors media files updates'

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root: su - (then sh cp-freebsd.sh)"; exit 1; }
  local s start bak
  for s; do in_list "$s" $STEPS || { echo "Unknown step '$s'. Steps: $STEPS"; exit 1; }; done
  [ $# -gt 0 ] || ask "Forensics Questions answered already?" || { echo "Do those first."; exit 1; }
  touch "$LOG"
  bak=/root/etc-backup-$(date +%H%M%S).tgz
  start=$(wc -l < "$LOG" | tr -d ' ')
  tar czf "$bak" /etc /usr/local/etc /boot/loader.conf 2>/dev/null; log "backed up /etc, /usr/local/etc and loader.conf to $bak"
  if [ $# -gt 0 ]; then
    for s; do "step_$s"; done
  else
    for s in $STEPS; do ask "Run step: $s?" && "step_$s"; done
  fi
  hdr "Changes this run"
  tail -n +"$((start + 1))" "$LOG"
  echo "Lost points? Undo that change. Restore one file: tar xzf $bak -C / etc/<path>"
}

[ -n "${CP_NO_MAIN:-}" ] || main "$@"
