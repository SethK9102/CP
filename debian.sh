#!/usr/bin/env bash
set -u
export DEBIAN_FRONTEND=noninteractive

LOG=/root/cp-log.txt
ME=${SUDO_USER:-}
AUTH=() ADMINS=()

log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
ask() { local a; read -rp "$1 [y/N] " a; [[ $a == [yY]* ]]; }
hdr() { printf '\n===== %s =====\n' "$*"; }
in_list() { local x=$1 y; shift; for y; do [[ $x == "$y" ]] && return 0; done; return 1; }
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

purge() {
  local p=$1
  local -a extra
  mapfile -t extra < <(apt-get -s purge "$p" 2>/dev/null | awk '/^(Purg|Remv) / {sub(/:.*/, "", $2); print $2}' | grep -vxF "${p%%:*}")
  if ((${#extra[@]})); then
    echo "  Purging $p also removes ${#extra[@]} other package(s): ${extra[*]:0:25}$( ((${#extra[@]} > 25)) && echo ' ...')"
    echo "  (if one of them is a desktop meta-package, a later autoremove can take much of the desktop with it)"
    ask "  Purge $p and those?" || return 1
  fi
  apt-get purge -y "$p" && log "purged $p${extra[*]:+ (also removed: ${extra[*]})}"
}

set_kv() {
  local f=$1 k=$2 v=$3 s=${4:- }
  [[ -f $f ]] || return 0
  if grep -Eq "^[#[:space:]]*$k([[:space:]]|=)" "$f"; then
    sed -Ei "s@^[#[:space:]]*$k([[:space:]]|=).*@$k$s$v@" "$f"
  else
    echo "$k$s$v" >> "$f"
  fi
  log "$f: $k$s$v"
}

UA='Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'
README_CACHE=/root/cp-readme.html

saved_readme() {
  local f
  while IFS= read -r f; do
    [[ $f == *[Rr][Ee][Aa][Dd][Mm][Ee]* ]] || grep -qi 'Authorized Administrators' "$f" 2>/dev/null || continue
    echo "$f"; return
  done < <(find /home/*/Desktop /root/Desktop /home/*/Downloads /home/*/ -maxdepth 1 -type f \
      \( -iname '*readme*' -o -iname '*.htm' -o -iname '*.html' -o -iname '*.mhtml' \) ! -name '*.desktop' \
      -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
}

session_env() {
  local pid
  for pid in $(pgrep -u "$1" -x 'chromium|chrome|mate-session|gnome-session-b|xfce4-session|cinnamon-sessio|plasmashell'; pgrep -u "$1"); do
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qE '^(DISPLAY|WAYLAND_DISPLAY)=' || continue
    cat "/proc/$pid/environ"; return 0
  done
  return 1
}

as_user() {
  local u=$1 uid home disp xa f; shift
  local -a envs=()
  mapfile -d '' envs < <(session_env "$u")
  if ((${#envs[@]})); then runuser -u "$u" -- env -i "${envs[@]}" "$@"; return; fi
  uid=$(id -u "$u") home=$(getent passwd "$u" | cut -d: -f6)
  disp=${DISPLAY:-}
  [[ -n $disp ]] || { disp=$(ls /tmp/.X11-unix 2>/dev/null | head -n1); disp=${disp:+:${disp#X}}; }
  xa=${XAUTHORITY:-}
  for f in "$home/.Xauthority" /run/user/"$uid"/gdm/Xauthority; do [[ -z $xa && -f $f ]] && xa=$f; done
  runuser -u "$u" -- env HOME="$home" USER="$u" PATH=/usr/local/bin:/usr/bin:/bin DISPLAY="${disp:-:0}" ${xa:+XAUTHORITY="$xa"} \
    XDG_RUNTIME_DIR=/run/user/"$uid" DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$uid"/bus "$@"
}

open_in_browser() {
  id "$1" &>/dev/null || return 1
  as_user "$1" setsid xdg-open "$2" >/dev/null 2>&1 &
}

browser_dump() {
  local u=$1 url=$2 bin home src tmp p
  bin=$(command -v chromium chromium-browser google-chrome-stable google-chrome 2>/dev/null | head -n1)
  [[ -n $bin ]] && id "$u" &>/dev/null || return 1
  home=$(getent passwd "$u" | cut -d: -f6)
  for p in "$home/.config/chromium" "$home/snap/chromium/common/chromium" "$home/.config/google-chrome"; do
    [[ -f $p/Default/Cookies ]] && { src=$p; break; }
  done
  [[ -n ${src:-} ]] || return 1
  tmp=$home/cp-browser-copy
  rm -rf "$tmp"; runuser -u "$u" -- mkdir -p "$tmp/Default" || return 1
  for p in "Local State" Default/Cookies Default/Cookies-journal; do
    [[ -e $src/$p ]] && runuser -u "$u" -- cp "$src/$p" "$tmp/$p"
  done
  as_user "$u" timeout 60 "$bin" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --ignore-certificate-errors --user-data-dir="$tmp" --virtual-time-budget=8000 --dump-dom "$url" 2>/dev/null
  rm -rf "$tmp"
}

fetch_readme() {
  local url=$1 owner=$2 page final saved a err tries=0
  command -v wget >/dev/null || apt-get install -y wget >&2
  err=$(mktemp)
  while :; do
    tries=$((tries + 1))
    page=$(wget -nv -O- -U "$UA" "$url" 2>"$err") || page=$(wget -nv -O- -U "$UA" --no-check-certificate "$url" 2>>"$err")
    if grep -qi 'Authorized' <<< "$page"; then rm -f "$err"; printf '%s\n' "$page"; return 0; fi
    final=$(grep -oE 'URL:[^ ]+' "$err" | tail -n1); final=${final#URL:}
    if ((tries == 1)); then
      grep -E 'ERROR' "$err" | sort -u >&2
      echo "README: a web filter or sign-in page answered instead of the README:" >&2
      echo "README:   ${final:0:120}" >&2
    fi
    if [[ -n $owner ]]; then
      echo "README: trying through $owner's Chromium sign-in..." >&2
      page=$(browser_dump "$owner" "$url")
      if grep -qi 'Authorized' <<< "$page"; then
        echo "README: got it through the browser." >&2
        rm -f "$err"; printf '%s\n' "$page"; return 0
      fi
    fi
    saved=$(saved_readme)
    if [[ -n $saved ]] && grep -qi 'Authorized' "$saved"; then
      echo "README: using the saved copy $saved" >&2
      rm -f "$err"; cat "$saved"; return 0
    fi
    if ((tries == 1)); then
      if [[ -n $owner ]] && open_in_browser "$owner" "$url"; then
        echo "README: opened the README in $owner's Chromium. Sign in there if the filter asks." >&2
      else
        echo "README: open the CyberPatriot README icon on the Desktop and sign in if the filter asks." >&2
      fi
      echo "README: once the README shows in the browser, wait about 30 seconds (Chromium saves its" >&2
      echo "README: sign-in every 30 s), then press Enter. Saving the page with Ctrl+S also works." >&2
    else
      echo "README: still blocked. Wait 30 seconds and press Enter, or save the page with Ctrl+S first." >&2
    fi
    read -rp "README: press Enter to try again, or type s to skip and type the users yourself: " a &&
      [[ $a != [sS]* ]] || { rm -f "$err"; return 1; }
  done
}

readme_text() {
  local f=${README:-} url owner page
  if [[ -z $f ]]; then
    if [[ -s $README_CACHE ]] && grep -qi 'Authorized' "$README_CACHE"; then f=$README_CACHE
    else f=$(saved_readme)
      [[ -n $f ]] || f=$(find /home/*/Desktop /root/Desktop /opt/CyberPatriot -maxdepth 1 \( -type f -o -type l \) \
          -iname '*readme*' 2>/dev/null | sort | head -n1)
    fi
  fi
  if [[ ! -f $f ]]; then
    echo "README: none found on a Desktop. Re-run as: sudo README=/path/to/file bash cp-linux.sh" >&2
    return 0
  fi
  if [[ $f == *.desktop ]]; then
    url=$(sed -nE 's/^(URL|Exec)(\[[^]]*\])?=//p' "$f" | grep -oE "(https?|file)://[^\"' ]+|/[^\"' ]+\.(html?|txt|aspx)" | head -n1)
    url=${url//%20/ }
    echo "README: $f -> ${url:-no link found}" >&2
    owner=${ME:-}; [[ -n $owner ]] || owner=$(stat -c %U "$f")
    [[ $owner == root ]] && owner=''
    case $url in
      file://*) page=$(cat "${url#file://}") ;;
      /*) page=$(cat "$url") ;;
      http*) page=$(fetch_readme "$url" "$owner") || return 0 ;;
    esac
    grep -qi 'Authorized' <<< "$page" && printf '%s\n' "$page" > "$README_CACHE"
    printf '%s\n' "$page"
  else
    echo "README: $f" >&2
    cat "$f"
  fi | sed -E -e 's#<h[1-6][^>]*>#\n== #gI' -e 's#<(br|/p|/li|/div|/tr|/td|/h[1-6]|pre|/pre)[^>]*>#\n#gI' \
              -e 's/<[^>]*>//g' -e 's/&nbsp;|&#160;/ /g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&amp;/\&/g' \
              -e 's/\r$//' -e '/^[[:space:]]*$/d'
}

readme_names() {
  awk -v h="$2:" '
    !on && index($0, h) {on=1; $0 = substr($0, index($0, h) + length(h)); if ($0 !~ /[^[:space:]]/) next}
    !on || /^[[:space:]]*$/ || tolower($1) ~ /^password/ {next}
    /Authorized/ || $1 !~ /^[a-z_][a-z0-9_.-]*$/ {exit}
    {print $1}' <<< "$1"
}

readme_groups() {
  perl -ne '
    s/\xe2\x80[\x98\x99\x9c\x9d]/"/g;
    if (defined $g) {
      if (/^\s*([a-z_][a-z0-9_.-]*)\s*$/) { $m .= " $1"; next }
      print "$g|$m\n"; undef $g;
    }
    next unless /create (?:a |the )?(?:new )?(?:\w+ )?group (?:(?:called|named) ["\x27]?([\w.-]+)|["\x27]([\w.-]+)["\x27])/i;
    my $name = defined $1 ? $1 : $2;
    my @m;
    if (/:\s*(.*\S)\s*$/) {
      @m = grep { /^[a-z_][a-z0-9_.-]*$/ && $_ ne "and" } map { s/^\W+|[^\w]+$//gr } split /[\s,]+/, $1;
    } elsif (/:\s*$/) { $g = $name; $m = ""; next }
    print "$name|@m\n";
    END { print "$g|$m\n" if defined $g }' <<< "$1" | sed 's/| /|/'
}

readme_todo() {
  grep -iE '\<(create|install|update|up.to.date|keep|kept|enable|disable|default|must|should|not authori[sz]ed|prohibited|remove)\>' <<< "$1" |
    grep -viE 'forensics|unique identifier|scoring report|CCS Client|time ?zone|JavaScript|Stop Scoring|home directories|auto-?login|scoring engine'
}

readme_service_text() {
  local s
  s=$(awk '
    tolower($0) ~ /critical services/ {on=1; sub(/.*[Cc]ritical [Ss]ervices:?/, ""); if ($0 ~ /[^[:space:]]/) print; next}
    on && (/^== / || /:[[:space:]]*$/) {exit}
    on {print}' <<< "$1")
  if [[ -n ${s//[[:space:]]/} ]]; then echo "$s"; else echo "$1"; fi
}

step_audit() {
  hdr "APT sources (remove anything odd)"
  grep -Hv '^\s*#' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -v ':$'
  hdr "Held packages (blocked from updating; unhold in the updates step)"
  apt-mark showhold
  hdr "APT proxy settings (should be none)"
  grep -rni proxy /etc/apt/apt.conf /etc/apt/apt.conf.d 2>/dev/null
  hdr "Listening ports"
  ss -tulpn
  hdr "Non-root UID 0 accounts"
  awk -F: '$3==0 && $1!="root" {print $1}' /etc/passwd
  hdr "System accounts (UID<1000) with a login shell"
  awk -F: '$3<1000 && $3!=0 && $7!~/(nologin|false|sync)$/ {print $1, $7}' /etc/passwd
  hdr "Accounts with empty passwords"
  awk -F: '$2=="" {print $1}' /etc/shadow
  hdr "Weak password hashes (MD5 or DES; fix by setting a new password)"
  awk -F: '$2 ~ /^\$1\$/ || ($2 != "" && $2 !~ /^[$!*]/) {print $1}' /etc/shadow
  hdr "Duplicate UIDs, GIDs or names"
  cut -d: -f3 /etc/passwd | sort | uniq -d | sed 's/^/UID /'
  cut -d: -f1 /etc/passwd | sort | uniq -d | sed 's/^/user /'
  cut -d: -f3 /etc/group | sort | uniq -d | sed 's/^/GID /'
  cut -d: -f1 /etc/group | sort | uniq -d | sed 's/^/group /'
  hdr "/etc/hosts entries"
  grep -vE '^\s*(#|$)' /etc/hosts
  hdr "World-writable files in /etc"
  find /etc -xdev -type f -perm -0002 2>/dev/null
  hdr "Enabled services (look for anything odd)"
  systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | awk '{print $1}' | xargs
  local todo
  todo=$(readme_todo "$(readme_text)")
  if [[ -n $todo ]]; then
    hdr "README instructions to check off (the script does not do all of these)"
    sed 's/^/  - /' <<< "$todo"
  fi
  read -rp "Press Enter to continue..."
}

SUS='(\<nc\>|\<ncat\>|netcat|socat|/dev/(tcp|udp)/|bash -i|sh -i|mkfifo|python[0-9.]* -c|perl -e|php -r|ruby -e|base64 -d|curl |wget |telnet |\| *(ba)?sh\>|chmod [0-7+]*s|/dev/shm|LD_PRELOAD)'
STRONG='/dev/(tcp|udp)/|bash -i|sh -i *[>&]|mkfifo|nc(at)? .*-[ec] |nc\.traditional|socat .*exec|pty\.spawn|os\.dup2|fsockopen|eval\(\$_|shell_exec\(|passthru\('
GTFO='^(bash|sh|dash|zsh|ash|busybox|find|vi|vim|vim\.basic|vim\.tiny|nano|ed|less|more|python[0-9.]*|perl|ruby|php[0-9.]*|lua.*|node|cp|mv|tee|dd|cat|base64|xxd|env|awk|gawk|mawk|sed|tar|zip|nmap|nc|socat|wget|curl|gdb|strace|systemctl|chmod|chown|rsync|git|make|expect|tclsh.*)$'

unowned() {
  comm -23 <(sort -u) <(cat /var/lib/dpkg/info/*.list | sed -E 'p; s#^/(s?bin|lib[0-9x]*)/#/usr/\1/#' | sort -u)
}

review_lines() {
  local hits hit f n
  hits=$(grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' <<< "$1" | grep . | sort -u)
  [[ -n $hits ]] || { echo "  none"; return; }
  while IFS= read -r hit <&3; do
    f=${hit%%:*} n=${hit#*:} n=${n%%:*}
    echo "$hit"
    ask "  Comment out line $n of $f?" && sed -i "${n}s/^/#/" "$f" && log "commented out $f:$n"
  done 3<<< "$hits"
}

review_files() {
  local f
  [[ $# -gt 0 && -n ${1:-} ]] || { echo "  none"; return; }
  for f; do
    [[ -e $f ]] || continue
    echo "--- $f"
    if grep -Iq . "$f" 2>/dev/null; then head -n 15 "$f"; else file "$f" 2>/dev/null || echo "  (binary file)"; fi
    ask "  Delete $f?" && rm -f -- "$f" && log "deleted $f"
  done
}

review_units() {
  local f
  [[ $# -gt 0 && -n ${1:-} ]] || { echo "  none"; return; }
  for f; do
    echo "--- $f"
    grep -E '^(Exec|On[A-Z]|Listen|User)' "$f"
    ask "  Stop, disable and delete ${f##*/}?" || continue
    [[ $f == *.d/*.conf ]] || systemctl disable --now "${f##*/}" 2>/dev/null
    rm -f -- "$f" && log "removed unit $f"
  done
  systemctl daemon-reload
}

step_backdoors() {
  local -a list
  local f line name pid exe p

  hdr "Cron: suspicious lines + every user crontab entry"
  mapfile -t list < <(ls -d /etc/crontab /etc/anacrontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* \
    /etc/cron.weekly/* /etc/cron.monthly/* 2>/dev/null)
  review_lines "$(grep -nHsE "$SUS" "${list[@]}" /var/spool/cron/crontabs/*
                  grep -nHsvE '^[[:space:]]*(#|$)' /var/spool/cron/crontabs/*)"
  hdr "Cron files not from any package"
  mapfile -t list < <(find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly -type f 2>/dev/null | unowned)
  review_files "${list[@]}"
  hdr "at jobs (remove with atrm <id>)"
  command -v atq >/dev/null && atq

  hdr "systemd units not from any package"
  mapfile -t list < <({ find /etc/systemd/system /usr/lib/systemd/system /usr/local/lib/systemd -type f \
      \( -name '*.service' -o -name '*.timer' -o -name '*.socket' -o -path '*.d/*.conf' \) 2>/dev/null | unowned
    find /root/.config/systemd /home/*/.config/systemd -type f 2>/dev/null; })
  review_units "${list[@]}"

  hdr "rc.local commands"
  review_lines "$(grep -nHsvE '^[[:space:]]*(#|$|exit 0)' /etc/rc.local)"
  hdr "Shell startup files and autostart: suspicious lines"
  review_lines "$(grep -nHsE "$SUS|alias +(sudo|su|passwd|apt|apt-get|cat)=|PROMPT_COMMAND|trap " \
    /etc/profile /etc/profile.d/* /etc/bash.bashrc /etc/environment /etc/zsh/zshrc \
    /root/.bashrc /root/.profile /root/.bash_profile /root/.bash_logout \
    /home/*/.bashrc /home/*/.profile /home/*/.bash_profile /home/*/.bash_logout /home/*/.zshrc \
    /etc/xdg/autostart/*.desktop /home/*/.config/autostart/*.desktop \
    /etc/NetworkManager/dispatcher.d/* /etc/NetworkManager/dispatcher.d/*/* | grep -v '^/etc/profile.d/vte-')"
  hdr "Startup files not from any package (incl. NetworkManager dispatcher scripts)"
  mapfile -t list < <({ find /etc/profile.d /etc/xdg/autostart /etc/update-motd.d /etc/init.d /etc/NetworkManager/dispatcher.d \
      -type f ! -name 'debuginfod.*' 2>/dev/null | unowned
    ls -d /home/*/.config/autostart/* /root/.config/autostart/* 2>/dev/null; })
  review_files "${list[@]}"

  hdr "PAM backdoors (pam_exec, sufficient pam_permit)"
  review_lines "$(grep -nHsE 'pam_exec|sufficient[[:space:]]+pam_permit' /etc/pam.d/*)"
  hdr "/etc/ld.so.preload"
  [[ -s /etc/ld.so.preload ]] && review_files /etc/ld.so.preload || echo "  none"
  hdr "APT hooks (commands apt runs on every update or install)"
  mapfile -t list < <({ find /etc/apt/apt.conf.d -type f 2>/dev/null | unowned; ls -d /etc/apt/apt.conf 2>/dev/null; })
  review_lines "$(grep -nHsE 'Invoke|Install-Pkgs' "${list[@]}" /dev/null
                  grep -nHsE "$SUS" /etc/apt/apt.conf /etc/apt/apt.conf.d/*)"
  hdr "udev rules that run programs"
  mapfile -t list < <(find /etc/udev/rules.d /usr/lib/udev/rules.d -type f 2>/dev/null | unowned)
  review_lines "$(grep -nHsE 'RUN|PROGRAM|IMPORT\{program\}' "${list[@]}" /dev/null
                  grep -nHsE "$SUS" /etc/udev/rules.d/* /usr/lib/udev/rules.d/*)"
  hdr "SSH authorized_keys"
  for f in /root/.ssh/authorized_keys* /home/*/.ssh/authorized_keys*; do
    [[ -s $f ]] || continue
    echo "--- $f"; awk '{print $1, $NF}' "$f"
    ask "  Delete $f?" && rm -f -- "$f" && log "deleted $f"
  done

  hdr "SUID/SGID: shell-capable or not from any package"
  local -a suid odd
  mapfile -t suid < <(find / -xdev -type f -perm /6000 2>/dev/null)
  mapfile -t odd < <(printf '%s\n' "${suid[@]}" | unowned)
  for f in "${suid[@]}"; do
    [[ ${f##*/} =~ $GTFO ]] || in_list "$f" "${odd[@]}" || continue
    ls -l "$f"
    ask "  Remove SUID/SGID from $f?" && chmod u-s,g-s "$f" && log "chmod u-s,g-s $f"
  done
  hdr "Dangerous file capabilities"
  while IFS= read -r line <&3; do
    f=${line%% *}; echo "$line"
    ask "  Remove capabilities from $f?" && setcap -r "$f" && log "setcap -r $f"
  done 3< <(getcap -r / 2>/dev/null | grep -E 'cap_(setuid|setgid|dac_|sys_admin|sys_ptrace|chown|fowner)')

  hdr "Programs in bin dirs not from any package"
  mapfile -t list < <(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -xdev -type f 2>/dev/null | unowned)
  review_files "${list[@]}"
  hdr "Files containing reverse-shell / webshell code"
  mapfile -t list < <(grep -rlIsE "$STRONG" --exclude-dir=.cache --exclude-dir=.mozilla \
    /home /root /opt /usr/local /srv /var/www /tmp /var/tmp /dev/shm /etc)
  review_files "${list[@]}"
  hdr "Executable or hidden files in temp dirs"
  find /tmp /var/tmp /dev/shm -mindepth 1 \( -name '.*' -o -type f -perm -u+x \) \
    ! -name '.X*-unix' ! -name '.ICE-unix' ! -name '.font-unix' ! -name '.Test-unix' 2>/dev/null

  hdr "Suspicious listening processes"
  while IFS= read -r line <&3; do
    name=$(sed -nE 's/.*\(\("([^"]+)",pid=([0-9]+).*/\1/p' <<< "$line")
    pid=$(sed -nE 's/.*\(\("([^"]+)",pid=([0-9]+).*/\2/p' <<< "$line")
    [[ -n $pid ]] || continue
    exe=$(readlink "/proc/$pid/exe")
    [[ $name =~ ^(nc|ncat|netcat|nc\.traditional|nc\.openbsd|socat|python.*|perl|ruby|php|bash|sh|dash|zsh|.*telnetd)$ \
       || $exe =~ ^/(tmp|var/tmp|dev/shm|home|root)/ || $exe == *'(deleted)' ]] || continue
    echo "$line"
    echo "  exe: $exe"
    echo "  cmd: $(tr '\0' ' ' < "/proc/$pid/cmdline")"
    ask "  Kill pid $pid?" && kill -9 "$pid" && log "killed $pid ($name)"
  done 3< <(ss -tulpnH)
  hdr "Processes running from temp dirs or deleted binaries"
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    [[ $exe =~ ^/(tmp|var/tmp|dev/shm)/ || $exe == *'(deleted)' ]] || continue
    pid=${p#/proc/}
    echo "pid $pid: $exe :: $(tr '\0' ' ' < "$p/cmdline")"
    ask "  Kill pid $pid?" && kill -9 "$pid" && log "killed $pid ($exe)"
  done

  if ask "Check package files for tampering with debsums (takes a few minutes)?"; then
    apt-get install -y debsums && debsums -c 2>/dev/null
  fi
  echo "Killed something? Re-run this step: if it comes back, persistence is still somewhere."
}

step_repos() {
  hdr "Restore official APT repos"
  . /etc/os-release
  local f body u=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
  local comps="main restricted universe multiverse"
  case $ID in
    linuxmint)
      f=/etc/apt/sources.list.d/official-package-repositories.list
      body="deb http://packages.linuxmint.com $VERSION_CODENAME main upstream import backport

deb http://archive.ubuntu.com/ubuntu $u $comps
deb http://archive.ubuntu.com/ubuntu $u-updates $comps
deb http://archive.ubuntu.com/ubuntu $u-backports $comps

deb http://security.ubuntu.com/ubuntu/ $u-security $comps" ;;
    ubuntu)
      if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        f=/etc/apt/sources.list.d/ubuntu.sources
        body="Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: $u $u-updates $u-backports
Components: $comps
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: $u-security
Components: $comps
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
      else
        f=/etc/apt/sources.list
        body="deb http://archive.ubuntu.com/ubuntu $u $comps
deb http://archive.ubuntu.com/ubuntu $u-updates $comps
deb http://archive.ubuntu.com/ubuntu $u-backports $comps
deb http://security.ubuntu.com/ubuntu/ $u-security $comps"
      fi ;;
    debian)
      local c=$VERSION_CODENAME d="main contrib non-free non-free-firmware"
      if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
        f=/etc/apt/sources.list.d/debian.sources
        body="Types: deb
URIs: http://deb.debian.org/debian
Suites: $c $c-updates
Components: $d
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $c-security
Components: $d
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
        if grep -qvE '^[[:space:]]*(#|$)' /etc/apt/sources.list 2>/dev/null; then
          echo "/etc/apt/sources.list also has entries (cdrom or extra repos):"
          grep -vE '^[[:space:]]*(#|$)' /etc/apt/sources.list
          ask "Comment them out?" && cp -a /etc/apt/sources.list /etc/apt/sources.list.bak &&
            sed -Ei 's/^([[:space:]]*deb)/#\1/' /etc/apt/sources.list && log "commented out /etc/apt/sources.list"
        fi
      else
        f=/etc/apt/sources.list
        body="deb http://deb.debian.org/debian $c $d
deb http://deb.debian.org/debian $c-updates $d
deb http://security.debian.org/debian-security $c-security $d"
      fi ;;
    *) echo "Unknown distro '$ID', fix repos by hand."; return ;;
  esac
  echo "Current $f:"; cat "$f" 2>/dev/null
  printf '\nWill write:\n%s\n\n' "$body"
  ask "Write it? (old copy saved as $f.bak)" || return
  [[ -f $f ]] && cp -a "$f" "$f.bak"
  echo "$body" > "$f" && log "rewrote $f"
}

step_apt_update() { apt-get update; }

step_users() {
  hdr "Users"
  local text admins users
  command -v sudo >/dev/null || { apt-get install -y sudo && log "installed sudo"; }
  text=$(readme_text)
  admins=$(readme_names "$text" "Authorized Administrators" | xargs)
  users=$(readme_names "$text" "Authorized Users" | xargs)
  [[ -n $ME ]] || ME=$(grep -m1 '(you)' <<< "$text" | awk '{print $1}')
  if [[ -n $admins$users ]]; then echo "Parsed from README. Check against the README and edit if wrong."
  else echo "Could not read README users. Type them in."; fi
  echo "Also add any account the README tells you to create (to admins too if it should be one)."
  read -e -i "$admins $users" -rp "Authorized users (include admins): " -a AUTH
  read -e -i "$admins" -rp "Admins: " -a ADMINS
  [[ -n $ME ]] || read -rp "Your own login username: " ME
  if [[ ${#AUTH[@]} -eq 0 ]]; then echo "No users entered, skipping."; return; fi
  AUTH+=("$ME") ADMINS+=("$ME")

  for u in $(awk -F: '$3>=1000 && $3!=65534 {print $1}' /etc/passwd); do
    in_list "$u" "${AUTH[@]}" && continue
    ask "Delete unauthorized user '$u'?" && { deluser --remove-home "$u" 2>/dev/null || userdel -r "$u"; } && log "deleted user $u"
  done

  local nu ng uid shell home a
  for u in $(awk -F: '$3==0 && $1!="root" {print $1}' /etc/passwd); do
    if in_list "$u" "${AUTH[@]}"; then
      nu=$(awk -F: '$3>=1000 && $3<60000 {print $3}' /etc/passwd | sort -n | tail -n1)
      nu=$(( ${nu:-999} + 1 ))
      ask "Authorized user '$u' has UID 0 (full root powers). Give it UID $nu?" || continue
      getent group "$u" >/dev/null || groupadd "$u"
      ng=$(getent group "$u" | cut -d: -f3)
      awk -F: -v OFS=: -v u="$u" -v n="$nu" -v g="$ng" '$1==u {$3=n; if ($4==0) $4=g} 1' /etc/passwd > /etc/passwd.cp &&
        cat /etc/passwd.cp > /etc/passwd && rm -f /etc/passwd.cp
      home=$(getent passwd "$u" | cut -d: -f6)
      [[ $home == /home/* && -d $home ]] && chown -R "$u:" "$home"
      log "UID of $u: 0 -> $nu"
    else
      ask "'$u' has UID 0, a second root account. Delete it?" && userdel -f "$u" && log "deleted UID 0 account $u"
    fi
  done
  while IFS=: read -r u uid shell home <&3; do
    in_list "$u" "${AUTH[@]}" && continue
    echo "Hidden account '$u': UID $uid (system range) but it can log in (shell $shell, home $home)"
    read -rp "  (d)elete it, (l)ock it (no shell, no password), (k)eep? [k] " a
    case $a in
      d*) if [[ $home == /home/* ]]; then userdel -rf "$u"; else userdel -f "$u"; fi && log "deleted hidden account $u" ;;
      l*) usermod -s /usr/sbin/nologin "$u" && passwd -l "$u" >/dev/null && log "locked hidden account $u" ;;
    esac
  done 3< <(awk -F: '$3>0 && $3<1000 && $7 !~ /(nologin|false|sync|shutdown|halt)$/ {print $1":"$3":"$7":"$6}' /etc/passwd)
  for u in "${AUTH[@]}"; do
    id "$u" &>/dev/null && continue
    ask "README user '$u' missing. Create?" && adduser --gecos '' --disabled-password "$u" && log "created user $u"
  done

  local g gid
  for g in sudo admin wheel adm lxd docker lpadmin sambashare disk shadow; do
    getent group "$g" >/dev/null || continue
    for u in $(getent group "$g" | cut -d: -f4 | tr , ' '); do
      [[ $g != disk && $g != shadow ]] && in_list "$u" "${ADMINS[@]}" && continue
      [[ $g == adm && $(id -u "$u" 2>/dev/null || echo 0) -lt 1000 ]] && continue
      ask "Remove '$u' from group $g?" && gpasswd -d "$u" "$g" && log "removed $u from $g"
    done
    gid=$(getent group "$g" | cut -d: -f3)
    for u in $(awk -F: -v g="$gid" '$4==g && $1!="root" {print $1}' /etc/passwd); do
      getent group "$u" >/dev/null || continue
      ask "'$u' has primary group $g. Change it to '$u'?" && usermod -g "$u" "$u" && log "primary group of $u -> $u"
    done
  done
  for u in "${ADMINS[@]}"; do
    id "$u" &>/dev/null || continue
    id -nG "$u" | grep -qw sudo && continue
    ask "Add admin '$u' to sudo?" && usermod -aG sudo "$u" && log "added $u to sudo"
  done

  local line gname
  local -a groups members have
  mapfile -t groups < <(readme_groups "$text")
  ((${#groups[@]})) || echo "README asks for no new groups (that the script could find)."
  while :; do
    if ((${#groups[@]})); then
      line=${groups[0]} groups=("${groups[@]:1}")
      echo "README group '${line%%|*}' with members: ${line#*|}  (edit if wrong)"
    else
      read -rp "Another group the README asks for (name, Enter = none): " gname
      [[ -n $gname ]] || break
      line="$gname|"
    fi
    read -e -i "${line%%|*}" -rp "  Group name: " gname
    [[ -n $gname ]] || continue
    read -e -i "${line#*|}" -rp "  Members (space-separated): " -a members
    if ! getent group "$gname" >/dev/null; then
      ask "  Create group '$gname'?" || continue
      groupadd "$gname" && log "created group $gname" || continue
    fi
    read -ra have <<< "$(getent group "$gname" | cut -d: -f4 | tr , ' ')"
    for u in "${members[@]}"; do
      in_list "$u" "${have[@]}" && continue
      id "$u" &>/dev/null || { echo "  no user '$u': create it first (it must be in the authorized list)"; continue; }
      gpasswd -a "$u" "$gname" >/dev/null && log "added $u to $gname"
    done
    for u in "${have[@]}"; do
      in_list "$u" "${members[@]}" && continue
      ask "  '$u' is in $gname but not in the list. Remove?" && gpasswd -d "$u" "$gname" >/dev/null && log "removed $u from $gname"
    done
  done

  local pw
  read -rsp "New password for all authorized users except you (blank = skip): " pw; echo
  for u in "${AUTH[@]}"; do
    id "$u" &>/dev/null || continue
    if [[ -n $pw && $u != "$ME" ]]; then echo "$u:$pw" | chpasswd && log "password set: $u"; fi
    chage -M 90 -m 7 -W 14 -I 30 "$u"
  done
  local -a chg
  read -rp "Accounts that must change password at next login (blank = none): " -a chg
  for u in "${chg[@]}"; do id "$u" &>/dev/null && chage -d 0 "$u" && log "must change password: $u"; done
  echo "Before locking root: $ME must be able to use sudo (log out and in again if just added)."
  ask "Lock the root password?" && passwd -l root && log "root locked"
}

step_sudo() {
  hdr "sudoers"
  local bak=/root/sudoers-backup.tgz
  local -a list
  tar czf "$bak" /etc/sudoers /etc/sudoers.d 2>/dev/null
  echo "Risky lines: NOPASSWD, !authenticate, Defaults with '!', rules for single users (should be %sudo only):"
  review_lines "$(grep -nHsE 'NOPASSWD|!authenticate|^[[:space:]]*Defaults.*!|^[[:space:]]*[a-z_][a-z0-9_-]*[[:space:]]+[^=]+=' \
      /etc/sudoers /etc/sudoers.d/* | grep -vE '^[^:]+:[0-9]+:[[:space:]]*root[[:space:]]|^/etc/sudoers.d/mintupdate:')"
  hdr "sudoers.d files not from any package"
  mapfile -t list < <(find /etc/sudoers.d -type f ! -name README 2>/dev/null | unowned)
  review_files "${list[@]}"
  if ! grep -rqs use_pty /etc/sudoers /etc/sudoers.d; then
    echo 'Defaults use_pty' > /etc/sudoers.d/99-cp && chmod 440 /etc/sudoers.d/99-cp && log "sudo: use_pty"
  fi
  chown root:root /etc/sudoers && chmod 440 /etc/sudoers
  if ! visudo -c >/dev/null; then
    echo "sudoers no longer parses. Restoring the backup."
    rm -f /etc/sudoers.d/99-cp; tar xzf "$bak" -C / && log "restored sudoers from $bak"
  fi
}

step_passwords() {
  hdr "Password policy + lockout"
  set_kv /etc/login.defs PASS_MAX_DAYS 90
  set_kv /etc/login.defs PASS_MIN_DAYS 7
  set_kv /etc/login.defs PASS_WARN_AGE 14
  set_kv /etc/login.defs ENCRYPT_METHOD SHA512
  set_kv /etc/login.defs UMASK 027
  useradd -D -f 30 && log "new accounts lock after 30 days inactive"
  apt-get install -y libpam-pwquality
  local f=/etc/security/pwquality.conf
  set_kv $f minlen 12 ' = '
  for k in ucredit lcredit dcredit ocredit; do set_kv $f $k -1 ' = '; done

  printf 'Name: Lock account after failed logins\nDefault: yes\nPriority: 0\nAuth-Type: Primary\nAuth:\n\t[default=die]\tpam_faillock.so authfail\n' \
    > /usr/share/pam-configs/faillock
  printf 'Name: Count failed logins, reset on success\nDefault: yes\nPriority: 1024\nAuth-Type: Primary\nAuth:\n\trequisite\tpam_faillock.so preauth\nAccount-Type: Primary\nAccount:\n\trequired\tpam_faillock.so\n' \
    > /usr/share/pam-configs/faillock_notify
  f=/etc/security/faillock.conf
  set_kv $f deny 5 ' = '
  set_kv $f unlock_time 900 ' = '
  set_kv $f fail_interval 900 ' = '
  pam-auth-update --enable faillock faillock_notify --force
  if grep -q pam_faillock /etc/pam.d/common-auth && grep -q pam_unix /etc/pam.d/common-auth; then
    log "PAM: faillock on (5 tries, 15 min lock)"
  else
    echo "WARNING: faillock not in common-auth. Check /etc/pam.d/common-auth before logging out."
  fi

  sed -Ei 's/[[:space:]]nullok(_secure)?//g' /etc/pam.d/common-auth /etc/pam.d/common-password
  sed -Ei '/^password.*pam_unix\.so/{/remember=/!s/$/ remember=5/}' /etc/pam.d/common-password
  sed -Ei '/^password.*pam_pwquality\.so/{/minlen=/!s/$/ minlen=12 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1/}
           /^password.*pam_unix\.so/{/minlen=/!s/$/ minlen=12/}' /etc/pam.d/common-password
  log "PAM: nullok removed, remember=5"
  local u
  for u in $(awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null); do
    [[ $u == "$ME" ]] && { echo "Your account $u has no password: set one with 'passwd $u'."; continue; }
    ask "Account '$u' has no password. Lock it?" && passwd -l "$u" && log "locked empty-password account: $u"
  done
  echo "Test now: in a new terminal run 'su - $ME' and log in. Keep this root shell open until that works."
}

step_login() {
  hdr "Login screen: no guest, no autologin (LightDM on Mint, GDM on Debian GNOME, SDDM on KDE)"
  local f
  if [[ -d /etc/lightdm ]]; then
    mkdir -p /etc/lightdm/lightdm.conf.d
    printf '[Seat:*]\nallow-guest=false\n' > /etc/lightdm/lightdm.conf.d/99-cp.conf
    sed -Ei 's/^allow-guest=.*/allow-guest=false/; s/^(autologin-user.*)/#\1/' \
      /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf 2>/dev/null
    log "lightdm guest off, autologin commented out"
  fi
  f=/etc/gdm3/daemon.conf
  if [[ -f $f ]]; then
    grep -nE '^[[:space:]]*(AutomaticLogin|TimedLogin)' "$f"
    sed -Ei 's/^[[:space:]]*(AutomaticLogin|TimedLogin)/#&/' "$f"
    grep -q '^\[daemon\]' "$f" || printf '\n[daemon]\n' >> "$f"
    sed -i '/^\[daemon\]/a AutomaticLoginEnable=false\nTimedLoginEnable=false' "$f"
    log "gdm3: automatic and timed login off"
    f=/etc/gdm3/greeter.dconf-defaults
    if [[ -f $f ]] && ask "GDM: hide the user list on the login screen (CIS)?"; then
      sed -Ei 's/^#?[[:space:]]*disable-user-list=.*/disable-user-list=true/' "$f"
      grep -q '^disable-user-list=true' "$f" || sed -i '/^\[org\/gnome\/login-screen\]/a disable-user-list=true' "$f"
      log "gdm3: user list hidden"
    fi
  fi
  for f in /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
    [[ -f $f ]] && grep -qE '^[[:space:]]*User=' "$f" || continue
    sed -Ei 's/^([[:space:]]*User=)/#\1/' "$f" && log "sddm: autologin commented out in $f"
  done
}

step_firewall() {
  hdr "Firewall"
  apt-get install -y ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw logging on
  ufw --force enable && log "ufw enabled"
}

step_kernel() {
  hdr "sysctl + file permissions"
  local f=/etc/sysctl.conf kv
  [[ -f $f ]] || touch "$f"
  for kv in net.ipv4.tcp_syncookies=1 net.ipv4.ip_forward=0 \
            net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.default.accept_redirects=0 \
            net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.all.accept_source_route=0 \
            net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.all.log_martians=1 \
            net.ipv4.icmp_echo_ignore_broadcasts=1 net.ipv6.conf.all.accept_redirects=0 \
            kernel.randomize_va_space=2 fs.protected_symlinks=1 fs.protected_hardlinks=1 fs.suid_dumpable=0; do
    set_kv $f "${kv%%=*}" "${kv#*=}" =
  done
  sysctl -p
  for f in /etc/shadow /etc/shadow- /etc/gshadow /etc/gshadow-; do
    [[ -e $f ]] && chown root:shadow "$f" && chmod 640 "$f"
  done
  for f in /etc/passwd /etc/passwd- /etc/group /etc/group-; do
    [[ -e $f ]] && chown root:root "$f" && chmod 644 "$f"
  done
  chmod 440 /etc/sudoers
  chmod 1777 /tmp /var/tmp
  log "fixed shadow/passwd/group/sudoers/tmp perms"
}

user_gsettings() {
  runuser -u "$ME" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$ME")/bus" \
    gsettings set "$@" 2>/dev/null && log "gsettings $*"
}

step_misc() {
  hdr "auditd, AppArmor, Ctrl-Alt-Del, home dirs, screen lock"
  apt-get install -y auditd && systemctl enable --now auditd && auditctl -e 1 >/dev/null && log "auditd on"
  systemctl enable --now apparmor && log "apparmor on"
  command -v aa-status >/dev/null && aa-status | head -n 4
  systemctl mask ctrl-alt-del.target && log "ctrl-alt-del masked"
  local d
  for d in /home/*/; do chmod 750 "$d"; done
  log "home dirs 750"
  if [[ -n $ME ]] && id "$ME" &>/dev/null; then
    user_gsettings org.cinnamon.desktop.screensaver lock-enabled true
    user_gsettings org.cinnamon.desktop.screensaver lock-delay 0
    user_gsettings org.cinnamon.desktop.session idle-delay 300
    user_gsettings org.gnome.desktop.screensaver lock-enabled true
    user_gsettings org.gnome.desktop.screensaver lock-delay 0
    user_gsettings org.gnome.desktop.session idle-delay 300
    user_gsettings org.mate.screensaver lock-enabled true
    user_gsettings org.mate.session idle-delay 5
  fi
  hdr "Files with no owner or group (planted or left over)"
  find / -xdev \( -nouser -o -nogroup \) 2>/dev/null | head -n 30
}

BAD_PKGS=(john john-data hydra hydra-gtk nmap zenmap ophcrack ophcrack-cli wireshark wireshark-qt
  tshark aircrack-ng netcat-traditional ncat kismet ettercap-common ettercap-graphical dsniff nikto
  sqlmap medusa fcrackzip hashcat yersinia p0f telnetd inetutils-telnetd telnetd-ssl rsh-server
  rsh-redone-server talkd nis freeciv freeciv-client-gtk3 freeciv-client-gtk4 freeciv-client-qt
  freeciv-client-sdl freeciv-client-extras freeciv-server freeciv-data minetest supertux openarena wesnoth 0ad
  aisleriot gnome-mines gnome-games gnome-chess gnome-sudoku gnome-mahjongg gnome-robots
  gnome-nibbles gnome-klotski gnome-tetravex gnome-taquin four-in-a-row five-or-more hitori iagno
  lightsoff quadrapassel swell-foop tali kpat kmines deluge deluge-gtk transmission-gtk
  transmission-qt qbittorrent frostwire nmapsi4 youtube-dl yt-dlp
  x11vnc tightvncserver tigervnc-standalone-server tigervnc-scraping-server xrdp tftpd tftpd-hpa atftpd
  pdfcrack rarcrack sucrack crunch cewl ncrack patator masscan zmap netdiscover nbtscan arp-scan hping3
  dirb gobuster wfuzz wapiti skipfish bettercap macchanger driftnet dnsrecon fierce thc-ipv6
  bsdgames ninvaders nsnake pacman4console bastet moon-buggy greed nethack-console crawl angband
  supertuxkart extremetuxracer openttd frozen-bubble neverball pingus 2048-qt endless-sky manaplus
  amule nicotine ktorrent rtorrent qbittorrent-nox transmission-cli transmission-daemon)

apt_installed_by_hand() {
  ls -tr /var/log/apt/history.log* 2>/dev/null | xargs -r zcat -f | awk '
    /^Start-Date:/ {d=$2}
    /^Install:/ {
      n = split(substr($0, 10), a, /\), /)
      for (i = 1; i <= n; i++) if (a[i] !~ /automatic/) { p = a[i]; sub(/^ */, "", p); sub(/[: ].*/, "", p); print d, p }
    }' | awk '!seen[$2]++'
}

SELF_PKGS=(libpam-pwquality ufw auditd unattended-upgrades debsums sudo open-vm-tools-desktop wget curl ca-certificates)

step_packages() {
  local p d id u line
  local -a list
  hdr "Packages installed by hand after the OS (apt history). Skip anything the README needs."
  mapfile -t list < <(apt_installed_by_hand)
  for line in "${list[@]}"; do
    d=${line%% *} p=${line#* }
    installed "$p" || continue
    in_list "$p" "${SELF_PKGS[@]}" && continue
    ask "$p (installed $d). Purge?" && purge "$p"
  done
  if [[ -f /var/log/installer/initial-status.gz ]]; then
    hdr "Packages added since the OS was installed (kernels and libraries are normal)"
    comm -13 <(zcat /var/log/installer/initial-status.gz | awk '/^Package:/ {print $2}' | sort -u) \
      <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii" {print $2}' | sort -u) |
      grep -vE '^(linux-|lib)' | xargs
  fi
  hdr "Packages from a .deb file, not from any repo"
  while read -r p <&3; do
    ask "Purge $p?" && purge "$p"
  done 3< <(apt list --installed 2>/dev/null | awk -F/ '/,local\]/ {print $1}')

  hdr "Known prohibited software"
  for p in "${BAD_PKGS[@]}"; do
    installed "$p" || continue
    ask "Purge $p?" && purge "$p"
  done

  if command -v flatpak >/dev/null; then
    hdr "Flatpak apps (Mint installs apps this way too)"
    while IFS=$'\t' read -r id d <&3; do
      ask "Uninstall flatpak $d ($id)?" && flatpak uninstall -y --noninteractive "$id" && log "removed flatpak $id"
    done 3< <(flatpak list --system --app --columns=application,name 2>/dev/null)
    for d in /home/*/.local/share/flatpak/app/*/; do
      [[ -d $d ]] || continue
      u=$(stat -c %U "$d") id=$(basename "$d")
      ask "Uninstall $u's flatpak $id?" && runuser -u "$u" -- flatpak uninstall --user -y --noninteractive "$id" &&
        log "removed $u's flatpak $id"
    done
  fi
  if command -v snap >/dev/null; then
    hdr "Snap apps"
    while read -r p _ <&3; do
      [[ $p =~ ^(core[0-9]*|snapd|bare|gtk-common-themes|gnome-[0-9-]+|gtk[0-9]*-common-themes|firefox|snap-store|snapd-desktop-integration|mesa-.*)$ ]] && continue
      ask "Remove snap $p?" && snap remove --purge "$p" && log "removed snap $p"
    done 3< <(snap list 2>/dev/null | tail -n +2)
  fi
  hdr "Packages nothing needs any more (apt-get autoremove)"
  mapfile -t list < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv / {sub(/:.*/, "", $2); print $2}')
  if ((${#list[@]})); then
    echo "${#list[@]} package(s): ${list[*]:0:40}$( ((${#list[@]} > 40)) && echo ' ...')"
    ask "Remove them? (say no if desktop programs are in the list)" && apt-get autoremove -y && log "autoremove: ${list[*]}"
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
      'HostbasedAuthentication no' 'IgnoreRhosts yes' 'UsePAM yes' > /etc/ssh/sshd_config.d/00-cp.conf
    chmod 644 /etc/ssh/sshd_config.d/00-cp.conf && log "wrote /etc/ssh/sshd_config.d/00-cp.conf"
  fi
  local -a others
  mapfile -t others < <(find /etc/ssh/sshd_config.d -name '*.conf' ! -name 00-cp.conf 2>/dev/null)
  ((${#others[@]})) && grep -H . "${others[@]}" &&
    echo "^ other sshd_config.d files, check them (00-cp.conf is read first and wins)"
  sshd -t && systemctl restart ssh
  ufw allow 22/tcp
}

harden_vsftpd() {
  local f=/etc/vsftpd.conf
  set_kv $f anonymous_enable NO =
  set_kv $f anon_upload_enable NO =
  set_kv $f anon_mkdir_write_enable NO =
  set_kv $f local_enable YES =
  set_kv $f chroot_local_user YES =
  set_kv $f xferlog_enable YES =
  systemctl restart vsftpd
  ufw allow 21/tcp
}

harden_php() {
  local f
  for f in /etc/php/*/apache2/php.ini /etc/php/*/fpm/php.ini; do
    [[ -f $f ]] || continue
    set_kv "$f" expose_php Off ' = '
    set_kv "$f" display_errors Off ' = '
    set_kv "$f" allow_url_include Off ' = '
    set_kv "$f" allow_url_fopen Off ' = '
    set_kv "$f" disable_functions exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec ' = '
  done
  systemctl restart 'php*-fpm' 2>/dev/null
}

harden_apache2() {
  local f=/etc/apache2/conf-available/security.conf
  set_kv $f ServerTokens Prod
  set_kv $f ServerSignature Off
  set_kv $f TraceEnable Off
  sed -Ei 's/^([[:space:]]*Options[^#]*)[[:space:]]\+?Indexes\>/\1/; s/^([[:space:]]*Options)[[:space:]]*$/\1 None/' \
    /etc/apache2/apache2.conf /etc/apache2/sites-available/*.conf
  log "apache: Indexes removed"
  harden_php
  if apache2ctl configtest; then systemctl restart apache2; else echo "apache config test failed, check above."; fi
  ufw allow 80/tcp; ufw allow 443/tcp
}

harden_nginx() {
  local f=/etc/nginx/nginx.conf
  if grep -q server_tokens $f; then
    sed -Ei 's/^([[:space:]]*)#?[[:space:]]*server_tokens.*/\1server_tokens off;/' $f
  else
    sed -i '/^[[:space:]]*http[[:space:]]*{/a\        server_tokens off;' $f
  fi
  sed -Ei 's/autoindex[[:space:]]+on/autoindex off/' /etc/nginx/sites-available/* /etc/nginx/conf.d/*.conf 2>/dev/null
  log "nginx: server_tokens off, autoindex off"
  harden_php
  if nginx -t; then systemctl reload nginx; else echo "nginx config test failed, check above."; fi
  ufw allow 80/tcp; ufw allow 443/tcp
}

smb_set() {
  local f=/etc/samba/smb.conf
  if grep -Eqi "^[[:space:]]*$1[[:space:]]*=" "$f"; then
    sed -Ei "s@^[[:space:]]*$1[[:space:]]*=.*@   $1 = $2@I" "$f"
  else
    sed -i "/^\[global\]/a\   $1 = $2" "$f"
  fi
  log "smb.conf: $1 = $2"
}

harden_samba() {
  smb_set 'map to guest' never
  smb_set 'restrict anonymous' 2
  smb_set 'usershare allow guests' no
  smb_set 'server min protocol' SMB2
  smb_set 'smb encrypt' required
  sed -Ei 's/^([[:space:]]*)(guest ok|public)[[:space:]]*=[[:space:]]*yes/\1\2 = no/I' /etc/samba/smb.conf
  log "smb.conf: guest shares off"
  if testparm -s >/dev/null; then systemctl restart smbd; else echo "testparm failed, check smb.conf."; fi
  ufw allow samba
}

harden_mysql() {
  local f
  for f in /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mariadb.conf.d/50-server.cnf; do
    [[ -f $f ]] || continue
    ask "Only allow local database connections (bind-address 127.0.0.1)?" && set_kv "$f" bind-address 127.0.0.1 ' = '
    set_kv "$f" local-infile 0 ' = '
  done
  if mysql -uroot -e 'SELECT user, host FROM mysql.user;'; then
    ask "Delete anonymous users, remote root logins and the test database?" &&
      mysql -uroot -e "DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'); DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" &&
      log "mysql: removed anonymous users, remote root, test db"
  else
    echo "Could not log in as database root. Check users by hand: mysql -u root -p"
  fi
  systemctl restart mysql 2>/dev/null || systemctl restart mariadb
}

FF_PREFS=(browser.safebrowsing.malware.enabled=true browser.safebrowsing.phishing.enabled=true
  browser.safebrowsing.downloads.enabled=true browser.safebrowsing.downloads.remote.block_potentially_unwanted=true
  browser.safebrowsing.downloads.remote.block_uncommon=true dom.disable_open_during_load=true
  xpinstall.whitelist.required=true signon.rememberSignons=false dom.security.https_only_mode=true)

ff_policy() {
  local kv sep='' prefs=''
  for kv in "${FF_PREFS[@]}"; do
    prefs+="$sep\"${kv%%=*}\": {\"Value\": ${kv#*=}, \"Status\": \"locked\"}"
    sep=$',\n      '
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
  pgrep -x 'firefox|firefox-esr|firefox-bin|chromium|chromium-browser|chrome' >/dev/null &&
    echo "A browser is still running. Close it, or it may overwrite profile settings."
  local -a list
  local d f p

  if compgen -c | grep -qxE 'chromium|chromium-browser|google-chrome(-stable)?' || ls -d /etc/chromium* /etc/opt/chrome &>/dev/null; then
    echo "Existing Chromium/Chrome policy files (planted ones can turn off Safe Browsing or force-install extensions):"
    mapfile -t list < <(find /etc/chromium /etc/chromium-browser /etc/opt/chrome -path '*policies*' -name '*.json' ! -name cp.json 2>/dev/null)
    review_files "${list[@]}"
    for d in /etc/chromium/policies/managed /etc/chromium-browser/policies/managed /etc/opt/chrome/policies/managed; do
      mkdir -p "$d" && echo "$CHROME_POLICY" > "$d/cp.json" && chmod 644 "$d/cp.json" && log "wrote $d/cp.json"
    done
    echo "Check chrome://policy shows them."
  fi

  if [[ -d /usr/lib/firefox || -d /usr/lib/firefox-esr ]] || compgen -c | grep -qxE 'firefox(-esr)?'; then
    for d in /usr/lib/firefox/distribution /usr/lib/firefox-esr/distribution /etc/firefox/policies /etc/firefox-esr/policies; do
      [[ $d == /usr/lib/* && ! -d ${d%/distribution} ]] && continue
      f=$d/policies.json
      mkdir -p "$d"
      [[ -s $f ]] && { echo "--- old $f"; cat "$f"; cp -a "$f" "$f.bak"; }
      ff_policy > "$f" && chmod 644 "$f" && log "wrote $f"
    done
    for p in /home/*/.mozilla/firefox/*/ /root/.mozilla/firefox/*/ /home/*/snap/firefox/common/.mozilla/firefox/*/; do
      [[ -f $p/prefs.js ]] || continue
      [[ -s $p/user.js ]] && { echo "--- old $p/user.js"; cat "$p/user.js"; }
      for f in "${FF_PREFS[@]}"; do echo "user_pref(\"${f%%=*}\", ${f#*=});"; done > "$p/user.js"
      chown --reference="$p" "$p/user.js" && log "wrote ${p}user.js"
    done
    echo "Check about:policies shows them."
  fi
}

SERVICES=(openssh-server vsftpd pure-ftpd proftpd-core apache2 nginx samba mysql-server mariadb-server
  postgresql bind9 nfs-kernel-server snmpd squid xinetd postfix dovecot-core cups)

declare -A SVC_RE=(
  [openssh-server]='ssh' [vsftpd]='vsftpd' [pure-ftpd]='pure-?ftpd' [proftpd-core]='proftpd'
  [apache2]='apache|httpd' [nginx]='nginx' [samba]='samba|\<smb' [mysql-server]='mysql'
  [mariadb-server]='mariadb|mysql' [postgresql]='postgres' [bind9]='bind9' [nfs-kernel-server]='\<nfs\>'
  [snmpd]='snmp' [squid]='squid' [xinetd]='inetd' [postfix]='postfix' [dovecot-core]='dovecot' [cups]='cups'
)
declare -A SVC_KIND=(
  ['vsftpd pure-ftpd proftpd-core']='\<ftp'
  ['apache2 nginx']='web ?server|website|wordpress|\<php'
  ['mysql-server mariadb-server postgresql']='database|wordpress'
  ['samba']='file shar' ['bind9']='\<dns\>' ['squid']='proxy'
  ['postfix dovecot-core']='mail server|smtp|imap|pop3' ['cups']='printer|printing'
)
declare -A EXTRA_SVC=(
  [avahi-daemon]='avahi|mdns|bonjour|zeroconf' [cups-browsed]='cups|print' [rpcbind]='rpcbind|\<nfs\>|\<nis\>'
  [dnsmasq]='dnsmasq|\<dns\>|dhcp' [slapd]='ldap|slapd' [isc-dhcp-server]='dhcp' [rsync]='rsync'
)

svc_wanted() {
  local p=$1 src=$2 members m
  grep -qiE "${SVC_RE[$p]}" <<< "$src" && return 0
  for members in "${!SVC_KIND[@]}"; do
    [[ " $members " == *" $p "* ]] && grep -qiE "${SVC_KIND[$members]}" <<< "$src" || continue
    for m in $members; do grep -qiE "${SVC_RE[$m]}" <<< "$src" && return 1; done
    return 0
  done
  return 1
}

step_services() {
  hdr "Services: keep only what README needs"
  local text src p a def
  text=$(readme_text)
  src=$(readme_service_text "$text")
  if [[ -z $text ]]; then echo "README not found: no defaults, decide each one."
  elif [[ $src != "$text" ]]; then printf 'README critical services:\n%s\n\n' "$src"
  else echo "README has no 'Critical Services' section: matching against the whole README, double-check each."; fi

  for p in "${SERVICES[@]}"; do
    def=''
    if installed "$p"; then
      if [[ -n $text ]]; then
        if svc_wanted "$p" "$src"; then def=k; echo "$p: README needs it, keep and harden."
        else def=p; echo "$p: not in README, purge."; fi
      fi
      read -e -i "$def" -rp "$p: (k)eep/harden, (p)urge, (s)kip? " a
    else
      [[ -n $text ]] && grep -qiE "${SVC_RE[$p]}" <<< "$src" &&
        echo "README names $p but it is not installed. Install it if the README needs it."
      continue
    fi
    case $a in
      k*) case $p in
            openssh-server) harden_ssh ;;
            vsftpd) harden_vsftpd ;;
            pure-ftpd|proftpd-core) ufw allow 21/tcp; echo "Turn off anonymous login in its config by hand." ;;
            apache2) harden_apache2 ;;
            nginx) harden_nginx ;;
            samba) harden_samba ;;
            mysql-server|mariadb-server) harden_mysql ;;
            bind9) ufw allow 53 ;;
            postfix) ufw allow 25/tcp ;;
            dovecot-core) ufw allow 143/tcp; ufw allow 993/tcp ;;
            *) echo "No auto-hardening for $p, check its config by hand." ;;
          esac
          log "kept $p" ;;
      p*) purge "$p" ;;
    esac
  done

  hdr "Default services that are rarely needed"
  local s
  for s in $(printf '%s\n' "${!EXTRA_SVC[@]}" | sort); do
    systemctl is-enabled -q "$s" 2>/dev/null || systemctl is-active -q "$s" 2>/dev/null || continue
    def=''
    if [[ -n $text ]]; then
      if grep -qiE "${EXTRA_SVC[$s]}" <<< "$src"; then def=k; else def=d; fi
    fi
    read -e -i "$def" -rp "$s is enabled or running. (d)isable, (k)eep? " a
    [[ $a == d* ]] || continue
    systemctl disable --now "$s.socket" 2>/dev/null
    systemctl disable --now "$s.service" && log "disabled $s"
  done
}

step_media() {
  hdr "Media files"
  local -a media
  mapfile -t media < <(find /home /root /srv /var/www /opt /tmp -type f \( -iname '*.mp3' -o -iname '*.mp4' \
    -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.flac' -o -iname '*.aac' \
    -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.flv' \) \
    ! -path '/opt/CyberPatriot/*' 2>/dev/null)
  [[ ${#media[@]} -eq 0 ]] && { echo "None found."; return; }
  printf '%s\n' "${media[@]}"
  ask "Delete all ${#media[@]} files above?" && rm -f -- "${media[@]}" && log "deleted ${#media[@]} media files"
}

step_files() {
  hdr "Files with passwords or personal data (prohibited on most images)"
  local -a list
  mapfile -t list < <({
    find /home /root /srv /opt -xdev -type f \( -iname '*password*' -o -iname '*passwd*' -o -iname '*cred*' \
      -o -iname '*secret*' -o -iname '*.kdbx' -o -iname '*ssn*' -o -iname '*credit*' -o -iname '*customer*' \
      -o -iname '*.pcap' -o -iname '*.pcapng' \) ! -path '*/.mozilla/*' ! -path '*/.cache/*' ! -path '*/.config/*' 2>/dev/null
    grep -rlIsE '\<[0-9]{3}-[0-9]{2}-[0-9]{4}\>|\<[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}\>|passw(or)?d *[:=]' \
      --exclude-dir=.mozilla --exclude-dir=.cache --exclude-dir=.config --exclude-dir=.local /home /root /srv /opt
  } | sort -u)
  review_files "${list[@]}"

  hdr "Programs disguised as documents, pictures or media (answer forensics questions about them first)"
  mapfile -t list < <(find /home /root /opt /srv /var/www -xdev -type f -size -200M ! -path '/opt/CyberPatriot/*' \
    \( -iname '*.pdf' -o -iname '*.doc*' -o -iname '*.xls*' -o -iname '*.ppt*' -o -iname '*.od[tsp]' -o -iname '*.txt' \
       -o -iname '*.csv' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.mp3' \
       -o -iname '*.mp4' -o -iname '*.zip' -o -iname '*.html' \) \
    -exec sh -c 'for f; do [ "$(head -c4 "$f" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] && echo "$f"; done' _ {} + 2>/dev/null)
  review_files "${list[@]}"
}

step_updates() {
  hdr "Updates (slow)"
  local p
  while read -r p <&3; do
    ask "$p is held back from updates. Unhold?" && apt-mark unhold "$p" && log "unheld $p"
  done 3< <(apt-mark showhold)
  apt-get install -y unattended-upgrades
  printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Download-Upgradeable-Packages "1";' \
    'APT::Periodic::Unattended-Upgrade "1";' 'APT::Periodic::AutocleanInterval "7";' > /etc/apt/apt.conf.d/20auto-upgrades
  sed -Ei '/[Ss]ecurity/s@^([[:space:]]*)//[[:space:]]*"@\1"@' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null
  grep -HnE 'APT::Periodic::[A-Za-z-]+ +"0"' /etc/apt/apt.conf.d/* 2>/dev/null && echo "^ these turn updates off, fix them"
  systemctl unmask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null
  log "auto updates on"
  if [[ -n $ME ]] && id "$ME" &>/dev/null; then
    user_gsettings org.gnome.software download-updates true
    user_gsettings org.gnome.software allow-updates true
  fi
  command -v mintupdate-automation >/dev/null && mintupdate-automation upgrade enable && log "mintupdate automation on"
  [[ -n $ME ]] && id "$ME" &>/dev/null && user_gsettings com.linuxmint.updates refresh-schedule-enabled true
  apt-get -y full-upgrade && log "full-upgrade done"
  systemctl list-timers --all --no-pager 2>/dev/null | grep -E 'apt-daily|unattended'
  echo "Also check the GUI: Mint Update Manager > Preferences (Auto-refresh + Automation), or GNOME Software > Preferences on Debian."
}

STEPS=(audit repos apt_update users sudo passwords login firewall kernel misc packages services browsers backdoors media files updates)

main() {
  [[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
  local -a only=("${@//-/_}")
  local s
  for s in "${only[@]}"; do
    in_list "$s" "${STEPS[@]}" || { echo "Unknown step '$s'. Steps: ${STEPS[*]}"; exit 1; }
  done
  ((${#only[@]})) || ask "Forensics Questions answered already?" || { echo "Do those first."; exit 1; }
  touch "$LOG"
  local start bak=/root/etc-backup-$(date +%H%M%S).tgz
  start=$(wc -l < "$LOG")
  tar czf "$bak" /etc 2>/dev/null; log "backed up /etc to $bak"
  if ((${#only[@]})); then
    for s in "${only[@]}"; do "step_$s"; done
  else
    for s in "${STEPS[@]}"; do ask "Run step: $s?" && "step_$s"; done
  fi
  hdr "Changes this run"
  tail -n +"$((start + 1))" "$LOG"
  echo "Lost points? Undo that change. Restore one file: tar xzf $bak -C / etc/<path>"
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
