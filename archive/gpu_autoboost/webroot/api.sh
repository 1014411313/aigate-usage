#!/system/bin/sh
# GPU 智能升频 · WebUI 后端
#
# 约定：结果全走 stdout（逐行 KEY=VALUE），出错时 stderr 打 E/<原因码> 并非零退出。
# 与守护的并发靠「临时文件 + rename」保证：守护要么读到旧全文、要么读到新全文。

MODID=gpu_autoboost
DATA=/data/adb/gpu_autoboost
CONF=$DATA/config.conf
RUN=$DATA/run
STATUS=$RUN/status
LEARN=$DATA/learn.tsv
LEARN_AGG=$DATA/learn_agg.tsv
MODES=$DATA/app_modes.conf
GAMES=$DATA/games.conf
LOG=$DATA/gpud.log
PAUSE=$DATA/pause
LOCK=$DATA/gpud.lock
GPU=/sys/class/kgsl/kgsl-3d0

die() { echo "E/$1" >&2; exit 1; }

modroot() {
    for d in /data/adb/modules/$MODID /data/adb/ap/modules/$MODID; do
        [ -f "$d/module.prop" ] && { echo "$d"; return 0; }
    done
    return 1
}

alive() {
    [ -f "$LOCK" ] || return 1
    p=$(cat "$LOCK" 2>/dev/null)
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$p" ] || return 1
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q gpud
}

is_key() {
    case "$1" in
        INTERVAL_MS|BUSY_HIGH|BUSY_LOW|HOLD_UP|HOLD_DOWN|LEVEL_MIN|LEVEL_MAX|LEVEL_START|TH_CAP|TH_HIGH|TH_LOW|LEVEL_THERMAL|SCREEN_IDLE|LEARN|LEARN_FLUSH_S|GAME_BOOST|GAME_LEVEL) return 0 ;;
    esac
    return 1
}

# ── 查询 ──────────────────────────────────────────────────────

cmd_ping() { echo PONG; }

cmd_status() {
    if [ -f "$STATUS" ]; then
        cat "$STATUS"
    else
        echo "busy=0"
        echo "freq=0"
        echo "level=-1"
        echo "level_min=-1"
        echo "level_max=-1"
        echo "temp=0"
        echo "fg=-"
        echo "pid=0"
    fi
    if alive; then echo "alive=1"; else echo "alive=0"; fi
    if [ -f "$PAUSE" ]; then echo "paused=1"; else echo "paused=0"; fi
    for f in gpu_busy_percentage min_pwrlevel max_pwrlevel num_pwrlevels; do
        if [ -r "$GPU/$f" ]; then
            v=$(cat "$GPU/$f" 2>/dev/null)
            echo "raw_$f=$v"
        fi
    done
}

cmd_conf_get() {
    [ -f "$CONF" ] || die NO_CONF
    grep '=' "$CONF" | grep -v '^[[:space:]]*#'
}

cmd_levels() {
    [ -r "$GPU/num_pwrlevels" ] || die NO_GPU
    n=$(cat "$GPU/num_pwrlevels" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) die NO_GPU ;; esac
    echo "count=$n"
    i=0
    for f in $(cat "$GPU/gpu_available_frequencies" 2>/dev/null); do
        [ "$i" -ge "$n" ] && break
        echo "L$i=$((f / 1000000))"
        i=$((i + 1))
    done
}

cmd_log() {
    n=${1:-80}
    case "$n" in ''|*[!0-9]*) n=80 ;; esac
    [ "$n" -gt 400 ] && n=400
    [ -f "$LOG" ] || die NO_LOG
    tail -n "$n" "$LOG"
}

cmd_advice() {
    if [ ! -s "$LEARN_AGG" ]; then
        echo "learn=0"
        echo "rows=0"
        return 0
    fi
    echo "learn=1"
    rows=$(wc -l < "$LEARN_AGG" 2>/dev/null)
    case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    echo "rows=$rows"
    awk -F'\t' '
        NF >= 4 {
            pkg = $1; lvl = $2 + 0; busy = $3 + 0; cnt = $4 + 0; mhz = $5 + 0
            if (pkg == "-" || cnt < 2) next
            adv = "hold"
            why = "负载适中"
            if (busy >= 70 && lvl >= 5) { adv = "up"; why = "负载偏高且档位仍低，建议放宽下限" }
            else if (busy <= 25 && lvl >= 9) { adv = "down"; why = "负载很低，可以收紧省电" }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pkg, lvl, busy, cnt, mhz, adv, why
        }
    ' "$LEARN_AGG"
}

cmd_about() {
    r=$(modroot) || die NO_MOD
    echo "MOD=$r"
    echo "CONF=$CONF"
    echo "DATA=$DATA"
    echo "GPU=$GPU"
    echo "LEVELS=$(cat "$GPU/num_pwrlevels" 2>/dev/null)"
    echo "---PROP---"
    cat "$r/module.prop" 2>/dev/null
}

cmd_changelog() {
    r=$(modroot) || die NO_MOD
    [ -f "$r/CHANGELOG.md" ] || die NO_CHANGELOG
    cat "$r/CHANGELOG.md"
}

# ── 写入 ──────────────────────────────────────────────────────

cmd_conf_set() {
    k=$1
    v=$2
    [ -n "$k" ] || die BAD_KEY
    is_key "$k" || die BAD_KEY
    case "$v" in ''|*[!0-9]*) die NOT_NUM ;; esac

    case "$k" in
        INTERVAL_MS) [ "$v" -ge 50 ] && [ "$v" -le 2000 ] || die RANGE ;;
        BUSY_HIGH)   [ "$v" -ge 20 ] && [ "$v" -le 100 ] || die RANGE ;;
        BUSY_LOW)    [ "$v" -ge 1 ] && [ "$v" -le 95 ] || die RANGE ;;
        HOLD_UP|HOLD_DOWN|LEVEL_MIN|LEVEL_MAX|LEVEL_START)
                     [ "$v" -ge 0 ] && [ "$v" -le 200 ] || die RANGE ;;
        TH_CAP|SCREEN_IDLE|LEARN|GAME_BOOST) [ "$v" -le 1 ] || die RANGE ;;
        TH_HIGH)     [ "$v" -ge 35 ] && [ "$v" -le 110 ] || die RANGE ;;
        TH_LOW)      [ "$v" -ge 30 ] && [ "$v" -le 105 ] || die RANGE ;;
        LEVEL_THERMAL) [ "$v" -ge 0 ] && [ "$v" -le 100 ] || die RANGE ;;
        GAME_LEVEL)  [ "$v" -ge 0 ] && [ "$v" -le 200 ] || die RANGE ;;
        LEARN_FLUSH_S) [ "$v" -ge 60 ] && [ "$v" -le 3600 ] || die RANGE ;;
    esac

    [ -f "$CONF" ] || die NO_CONF
    awk -v k="$k" -v v="$v" '
        BEGIN { done = 0 }
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$CONF" > "$CONF.tmp.$$" 2>/dev/null || die WRITE
    mv -f "$CONF.tmp.$$" "$CONF" 2>/dev/null || { rm -f "$CONF.tmp.$$"; die WRITE; }
    chmod 0644 "$CONF" 2>/dev/null
    echo "OK $k=$v"
}

cmd_restart() {
    if [ -f "$LOCK" ]; then
        p=$(cat "$LOCK" 2>/dev/null)
        case "$p" in ''|*[!0-9]*) : ;; *) kill "$p" 2>/dev/null ;; esac
    fi
    sleep 1
    rm -f "$LOCK" 2>/dev/null
    r=$(modroot) || die NO_MOD
    nohup sh "$r/gpud" >/dev/null 2>&1 </dev/null &
    echo OK
}

cmd_stop() {
    if [ -f "$LOCK" ]; then
        p=$(cat "$LOCK" 2>/dev/null)
        case "$p" in ''|*[!0-9]*) : ;; *) kill "$p" 2>/dev/null ;; esac
    fi
    sleep 1
    rm -f "$LOCK" 2>/dev/null
    echo OK
}

cmd_pause() {
    mkdir -p "$DATA" 2>/dev/null
    : > "$PAUSE"
    echo "OK paused"
}

cmd_resume() {
    rm -f "$PAUSE" 2>/dev/null
    cmd_restart
}

cmd_learn_reset() {
    rm -f "$LEARN" "$LEARN_AGG" 2>/dev/null
    echo "OK learn_reset"
}

# ── 应用级档位锁定 ───────────────────────────────────────────
# app_modes.conf 每行 pkg=LEVEL：该应用在前台时守护把它钉死在这个档位，
# 不再按负载动态调整（采纳学习建议时写入）。

cmd_modes_list() {
    [ -f "$MODES" ] || return 0
    grep '=' "$MODES" 2>/dev/null | grep -v '^[[:space:]]*#'
}

cmd_mode_set() {
    pkg=$1
    lvl=$2
    [ -n "$pkg" ] && [ -n "$lvl" ] || die BAD_ARG
    case "$pkg" in
        *[!A-Za-z0-9._]*) die BAD_PKG ;;
    esac
    case "$lvl" in
        ''|*[!0-9]*) die NOT_NUM ;;
    esac
    [ "$lvl" -ge 0 ] && [ "$lvl" -le 20 ] || die RANGE

    mkdir -p "$DATA" 2>/dev/null
    if [ -f "$MODES" ]; then
        awk -v p="$pkg" -v v="$lvl" '
            BEGIN { done = 0 }
            index($0, p "=") == 1 { print p "=" v; done = 1; next }
            { print }
            END { if (!done) print p "=" v }
        ' "$MODES" > "$MODES.tmp.$$" 2>/dev/null || die WRITE
        mv -f "$MODES.tmp.$$" "$MODES" 2>/dev/null || { rm -f "$MODES.tmp.$$"; die WRITE; }
    else
        printf '%s=%s\n' "$pkg" "$lvl" > "$MODES" 2>/dev/null || die WRITE
    fi
    chmod 0644 "$MODES" 2>/dev/null
    echo "OK $pkg=$lvl"
}

cmd_mode_del() {
    pkg=$1
    [ -n "$pkg" ] || die BAD_ARG
    [ -f "$MODES" ] || die MISS
    awk -v p="$pkg" '
        index($0, p "=") == 1 { next }
        { print }
    ' "$MODES" > "$MODES.tmp.$$" 2>/dev/null || die WRITE
    mv -f "$MODES.tmp.$$" "$MODES" 2>/dev/null || { rm -f "$MODES.tmp.$$"; die WRITE; }
    echo "OK $pkg"
}

# ── 游戏名单 ───────────────────────────────────────────────
# games.conf 一行一个包名。命中名单的应用在前台时，守护不等负载爬升，
# 直接拉到 GAME_LEVEL（温控仍优先）。

cmd_games_list() {
    [ -f "$GAMES" ] || return 0
    grep -v '^[[:space:]]*#' "$GAMES" 2>/dev/null | grep -v '^[[:space:]]*$'
}

cmd_game_add() {
    pkg=$1
    [ -n "$pkg" ] || die BAD_ARG
    case "$pkg" in
        *[!A-Za-z0-9._]*) die BAD_PKG ;;
    esac
    mkdir -p "$DATA" 2>/dev/null
    if [ -f "$GAMES" ] && grep -qx "$pkg" "$GAMES" 2>/dev/null; then
        echo "DUP $pkg"
        return 0
    fi
    printf '%s\n' "$pkg" >> "$GAMES" 2>/dev/null || die WRITE
    chmod 0644 "$GAMES" 2>/dev/null
    echo "OK $pkg"
}

cmd_game_del() {
    pkg=$1
    [ -n "$pkg" ] || die BAD_ARG
    [ -f "$GAMES" ] || die MISS
    grep -vx "$pkg" "$GAMES" > "$GAMES.tmp.$$" 2>/dev/null || die WRITE
    mv -f "$GAMES.tmp.$$" "$GAMES" 2>/dev/null || { rm -f "$GAMES.tmp.$$"; die WRITE; }
    echo "OK $pkg"
}

cmd_apps_list() {
    pm list packages -3 2>/dev/null | sed 's/^package://'
}

# ── 检查更新 ───────────────────────────────────────────────
# 更新源是纯文本清单（每行 key=value）：version / versionCode / url / note
# 对比 versionCode 判断有无新版；只提示，不自动下载安装。

cmd_set_update_url() {
    url=$1
    [ -n "$url" ] || die BAD_ARG
    case "$url" in
        http://*|https://*) : ;;
        *) die BAD_URL ;;
    esac
    [ -f "$CONF" ] || die NO_CONF
    awk -v v="$url" '
        BEGIN { done = 0 }
        index($0, "UPDATE_URL=") == 1 { print "UPDATE_URL=" v; done = 1; next }
        { print }
        END { if (!done) print "UPDATE_URL=" v }
    ' "$CONF" > "$CONF.tmp.$$" 2>/dev/null || die WRITE
    mv -f "$CONF.tmp.$$" "$CONF" 2>/dev/null || { rm -f "$CONF.tmp.$$"; die WRITE; }
    echo "OK"
}

cmd_check_update() {
    r=$(modroot) || die NO_MOD
    url=$(grep -m1 '^UPDATE_URL=' "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    if [ -z "$url" ]; then
        echo "status=no_url"
        return 0
    fi

    cur=$(grep -m1 '^version=' "$r/module.prop" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    curc=$(grep -m1 '^versionCode=' "$r/module.prop" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    [ -n "$cur" ] || cur=-
    [ -n "$curc" ] || curc=0
    echo "cur=$cur"
    echo "cur_code=$curc"

    tmp=/data/local/tmp/gpu_ab_upd.$$
    ok=0
    if command -v curl >/dev/null 2>&1; then
        curl -s -L --max-time 15 "$url" -o "$tmp" 2>/dev/null && ok=1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O "$tmp" "$url" 2>/dev/null && ok=1
    fi
    if [ "$ok" != 1 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null
        echo "status=fetch_failed"
        return 0
    fi

    nv=$(grep -m1 '^version=' "$tmp" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    nc=$(grep -m1 '^versionCode=' "$tmp" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    nu=$(grep -m1 '^url=' "$tmp" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    nn=$(grep -m1 '^note=' "$tmp" 2>/dev/null | cut -d= -f2- | tr -d '\r')
    rm -f "$tmp" 2>/dev/null

    [ -n "$nv" ] || nv=-
    [ -n "$nu" ] || nu=-
    [ -n "$nn" ] || nn=-
    echo "new=$nv"
    echo "new_code=$nc"
    echo "url=$nu"
    echo "note=$nn"

    case "$nc" in
        ''|*[!0-9]*)
            echo "status=bad_manifest"
            return 0
            ;;
    esac
    case "$curc" in ''|*[!0-9]*) curc=0 ;; esac
    if [ "$nc" -gt "$curc" ]; then
        echo "status=update_available"
    else
        echo "status=up_to_date"
    fi
}

# ── 分发 ──────────────────────────────────────────────────────

case "$1" in
    ping)        cmd_ping ;;
    status)      cmd_status ;;
    conf_get)    cmd_conf_get ;;
    conf_set)    shift; cmd_conf_set "$@" ;;
    levels)      cmd_levels ;;
    log)         shift; cmd_log "$@" ;;
    advice)      cmd_advice ;;
    about)       cmd_about ;;
    changelog)   cmd_changelog ;;
    restart)     cmd_restart ;;
    stop)        cmd_stop ;;
    pause)       cmd_pause ;;
    resume)      cmd_resume ;;
    learn_reset) cmd_learn_reset ;;
    modes_list)  cmd_modes_list ;;
    mode_set)    shift; cmd_mode_set "$@" ;;
    mode_del)    shift; cmd_mode_del "$@" ;;
    games_list)  cmd_games_list ;;
    game_add)    shift; cmd_game_add "$@" ;;
    game_del)    shift; cmd_game_del "$@" ;;
    apps_list)   cmd_apps_list ;;
    check_update) cmd_check_update ;;
    set_update_url) shift; cmd_set_update_url "$@" ;;
    *)
        echo "usage: api.sh <ping|status|conf_get|conf_set|levels|log|advice|about|restart|stop|pause|resume|learn_reset>" >&2
        exit 2
        ;;
esac
