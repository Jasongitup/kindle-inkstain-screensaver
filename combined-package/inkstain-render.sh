#!/bin/sh
# ============================================================
# 墨痕锁屏渲染脚本 — Kindle 原生阅读统计锁屏壁纸
# 功能：读取 reading-time.tsv 和 cc.db，用 FBInk 绘制
#       KOReader 墨痕壁纸风格的锁屏界面
# 适配：Kindle Scribe 2022 (1860×2480, 300dpi)
# 依赖：Véra/KPM 系统级 FBInk + NotoSansCJKsc 字体
#       + 原生阅读记录守护进程 (reading-time.tsv)
# ============================================================

BASE="/mnt/us/reading-time"
DATA="$BASE/reading-time.tsv"
FBINK="/var/local/kmc/bin/fbink"
RFONT="$BASE/fonts/NotoSansCJKsc-Regular.otf"
BFONT="$RFONT"
CC_DB="/var/local/cc.db"
PROGRESS_DB="$BASE/cc-progress-viewer.db"
PROGRESS_CACHE="$BASE/book-progress.tsv"
LOG="$BASE/inkstain-render.log"

# Kindle Scribe 屏幕参数
W=1860
H=2480
MARGIN_X=120
MARGIN_Y=110
CONTENT_W=$((W - MARGIN_X * 2))

# 基于 KOReader 的 scale 体系：以 600x800 为基准，等比缩放
# Kindle Scribe: scale = min(1860/600, 2480/800) = 3.1
# KOReader 设有上下限，我们取实际计算值但施加合理 cap
SCALE_X=$((W / 600))
SCALE_Y=$((H / 800))
if [ "$SCALE_X" -lt "$SCALE_Y" ]; then SCALE="$SCALE_X"; else SCALE="$SCALE_Y"; fi
[ "$SCALE" -lt 1 ] && SCALE=1
[ "$SCALE" -gt 4 ] && SCALE=4

# 统计周期（天）
DAYS=7
TOP_N=5

# ========== 风格配置 ==========
# 风格选项: film(胶片票根), inkstain(墨痕壁纸), random(随机), alternate(轮流)
STYLE_CONF="$BASE/inkstain-style.conf"
STYLE_STATE="$BASE/inkstain-style.state"

# 读取风格配置，默认墨痕
read_style_config() {
    if [ -f "$STYLE_CONF" ]; then
        . "$STYLE_CONF" 2>/dev/null
    fi
    # style 变量来自配置文件，默认 inkstain
    : "${style:=inkstain}"
}

# 决定本次渲染使用的风格
resolve_style() {
    read_style_config
    case "$style" in
        film|inkstain)
            echo "$style"
            ;;
        random)
            # 随机选择 film 或 inkstain
            if awk -v seed="$$" 'BEGIN{srand(seed); exit (rand() < 0.5)}'; then
                echo "film"
            else
                echo "inkstain"
            fi
            ;;
        alternate)
            # 轮流：读取上次风格，切换
            last=""
            [ -f "$STYLE_STATE" ] && . "$STYLE_STATE" 2>/dev/null
            : "${last:=inkstain}"
            if [ "$last" = "film" ]; then
                echo "inkstain"
                echo "last=inkstain" > "$STYLE_STATE"
            else
                echo "film"
                echo "last=film" > "$STYLE_STATE"
            fi
            ;;
        *)
            echo "inkstain"
            ;;
    esac
}

# ========== 竞态防护：状态检查 + 帧缓冲验证 ==========

# 验证点坐标（由渲染函数设置，用于事后确认画面未被覆盖）
VERIFY_X=""
VERIFY_Y=""

# 检查设备是否仍在屏保状态（返回0=仍在屏保，1=已唤醒）
# 环境变量 SKIP_STATE_CHECK=1 可跳过检查（用于直接测试）
check_power_state() {
    [ "$SKIP_STATE_CHECK" = "1" ] && return 0
    state=$(lipc-get-prop com.lab126.powerd state 2>/dev/null || echo "")
    case "$state" in
        active)
            echo "$(date): device is active (woken), aborting"
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# 验证帧缓冲：检查验证点是否仍为黑色（我们的内容还在）
# 返回0=画面完好，1=被覆盖
verify_framebuffer() {
    # 若无验证点，跳过
    if [ -z "$VERIFY_X" ] || [ -z "$VERIFY_Y" ]; then
        return 0
    fi

    # 读取帧缓冲格式
    bpp=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null || echo 8)
    stride=$(cat /sys/class/graphics/fb0/stride 2>/dev/null || echo 1860)

    # 计算字节偏移
    bytes_per_pixel=$((bpp / 8))
    [ "$bytes_per_pixel" -lt 1 ] && bytes_per_pixel=1
    offset=$((VERIFY_Y * stride + VERIFY_X * bytes_per_pixel))

    # 读取 1 个字节，用 printf 转为数值
    raw_byte=$(dd if=/dev/fb0 bs=1 skip="$offset" count=1 2>/dev/null)
    val=$(printf '%d' "'$raw_byte" 2>/dev/null || echo "")

    # 空值跳过（无法读取）
    [ -z "$val" ] && return 0
    # 黑色判定：值 < 50 表示我们的内容仍在
    [ "$val" -lt 50 ] && return 0
    echo "$(date): framebuffer verify failed at ($VERIFY_X,$VERIFY_Y) val=$val"
    return 1
}

exec >> "$LOG" 2>&1

# ========== FBInk 绘图函数 ==========

# 左对齐文本：ot <px> <top> <left> <right_x> <style> <message>
# Faux bold: BOLD style renders twice with 1px offset for heavier strokes
ot() {
    ot_size="$1"; ot_top="$2"; ot_left="$3"; ot_right="$4"; ot_style="$5"; ot_msg="$6"
    [ -z "$ot_msg" ] && ot_msg=" "
    ot_rm=$((W - ot_right))
    "$FBINK" -q -b -t "regular=$RFONT,bold=$BFONT,px=$ot_size,top=$ot_top,left=$ot_left,right=$ot_rm,style=$ot_style" "$ot_msg" 2>>"$LOG"
    if [ "$ot_style" = "BOLD" ]; then
        "$FBINK" -q -b -t "regular=$RFONT,bold=$BFONT,px=$ot_size,top=$ot_top,left=$((ot_left+1)),right=$ot_rm,style=$ot_style" "$ot_msg" 2>>"$LOG"
    fi
}

# 居中文本：ot_center <px> <top> <left> <right_x> <style> <message>
ot_center() {
    oc_size="$1"; oc_top="$2"; oc_left="$3"; oc_right="$4"; oc_style="$5"; oc_msg="$6"
    [ -z "$oc_msg" ] && oc_msg=" "
    oc_rm=$((W - oc_right))
    "$FBINK" -q -b -m -t "regular=$RFONT,bold=$BFONT,px=$oc_size,top=$oc_top,left=$oc_left,right=$oc_rm,style=$oc_style" "$oc_msg" 2>>"$LOG"
    if [ "$oc_style" = "BOLD" ]; then
        "$FBINK" -q -b -m -t "regular=$RFONT,bold=$BFONT,px=$oc_size,top=$oc_top,left=$((oc_left+1)),right=$oc_rm,style=$oc_style" "$oc_msg" 2>>"$LOG"
    fi
}

# 矩形填充：rect <top> <left> <width> <height> <color>
rect() {
    "$FBINK" -q -b -B "$5" -k "top=$1,left=$2,width=$3,height=$4" 2>/dev/null
}

# 水平线：hline <top> <left> <width>
hline() {
    rect "$1" "$2" "$3" 2 BLACK
}

# 垂直线：vline <top> <left> <height>
vline() {
    rect "$1" "$2" 2 "$3" BLACK
}

# ========== 时间格式化 ==========

# 格式化时长为 "Xh Ym" 或 "Xm" 或 "Xs"
format_time() {
    n="$1"
    [ -z "$n" ] && n=0
    h=$((n / 3600)); m=$(( (n % 3600) / 60 )); s=$((n % 60))
    if [ "$h" -gt 0 ]; then
        printf '%dh %dm' "$h" "$m"
    elif [ "$m" -gt 0 ]; then
        printf '%dm %ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

# 格式化时长为中文 "X小时X分"
format_time_cn() {
    n="$1"
    [ -z "$n" ] && n=0
    h=$((n / 3600)); m=$(( (n % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then
        printf '%s小时%s分' "$h" "$m"
    elif [ "$m" -gt 0 ]; then
        printf '%s分' "$m"
    else
        printf '不足1分'
    fi
}

# 格式化总天数为 "X天"
format_days() {
    n="$1"
    [ -z "$n" ] && n=0
    if [ "$n" -lt 86400 ]; then
        printf '不足1天'
    else
        d=$((n / 86400))
        printf '%s天' "$d"
    fi
}

# ========== 日期计算 ==========
# 纯 shell 算术实现，仅依赖 date +%Y-%m-%d（与 daemon 一致）
# 不使用 date -d / date -r / awk strftime（Kindle busybox 不支持）

# 获取 N 天前的日期 (YYYY-MM-DD)
days_ago_date() {
    n="$1"
    today_str=$(date +%Y-%m-%d)
    year=${today_str%%-*}
    rest=${today_str#*-}
    month=${rest%%-*}
    day=${rest#*-}
    # 去掉前导零，避免 busybox 将 08/09 当作八进制报错
    case "$month" in 0*) month=${month#0};; esac
    case "$day" in 0*) day=${day#0};; esac

    # Gregorian → Julian Day Number
    ja=$(( (14 - month) / 12 ))
    jy=$(( year + 4800 - ja ))
    jm=$(( month + (12 * ja) - 3 ))
    jdn=$(( day + ((153 * jm + 2) / 5) + (365 * jy) + (jy / 4) - (jy / 100) + (jy / 400) - 32045 ))
    jdn=$(( jdn - n ))

    # Julian Day Number → Gregorian
    ja=$(( jdn + 32044 ))
    jb=$(( (4 * ja + 3) / 146097 ))
    jc=$(( ja - ((146097 * jb) / 4) ))
    jd=$(( (4 * jc + 3) / 1461 ))
    je=$(( jc - ((1461 * jd) / 4) ))
    jm=$(( (5 * je + 2) / 153 ))
    day=$(( je - ((153 * jm + 2) / 5) + 1 ))
    month=$(( jm + 3 - (12 * (jm / 10)) ))
    year=$(( (100 * jb) + jd - 4800 + (jm / 10) ))

    printf '%04d-%02d-%02d' "$year" "$month" "$day"
}

# 获取 N 天前的短日期 (MM.DD)
days_ago_short() {
    full=$(days_ago_date "$1")
    rest=${full#*-}
    month=${rest%%-*}
    day=${full##*-}
    printf '%s.%s' "$month" "$day"
}

# ========== 数据收集 ==========

# 刷新书籍进度缓存（从 cc.db 只读快照）
refresh_progress_cache() {
    rm -f "$PROGRESS_DB" "$PROGRESS_CACHE" "$PROGRESS_CACHE.new"
    if command -v sqlite3 >/dev/null 2>&1 && [ -r "$CC_DB" ] && cp "$CC_DB" "$PROGRESS_DB" 2>/dev/null; then
        sqlite3 -readonly -separator "$(printf '\t')" "$PROGRESS_DB" \
            "SELECT CAST(p_percentFinished + 0.5 AS INTEGER), replace(replace(p_titles_0_nominal, char(9), ' '), char(10), ' ') FROM Entries WHERE p_titles_0_nominal IS NOT NULL AND p_percentFinished >= 0 AND p_percentFinished <= 100 ORDER BY p_lastAccess DESC;" \
            > "$PROGRESS_CACHE.new" 2>/dev/null || true
        [ -s "$PROGRESS_CACHE.new" ] && mv "$PROGRESS_CACHE.new" "$PROGRESS_CACHE"
    fi
    rm -f "$PROGRESS_DB" "$PROGRESS_CACHE.new"
}

# 查询书籍进度百分比
get_book_progress() {
    title="$1"
    [ -f "$PROGRESS_CACHE" ] || return
    progress=$(awk -F '\t' -v t="$title" '$2==t{print $1;exit}' "$PROGRESS_CACHE")
    case "$progress" in '' | *[!0-9]*) return ;; esac
    [ "$progress" -gt 100 ] && progress=100
    echo "$progress"
}

# 收集统计数据，写入全局变量
collect_stats() {
    today_date=$(date +%Y-%m-%d)
    start_date=$(days_ago_date $((DAYS - 1)))
    end_date=$today_date
    start_short=$(days_ago_short $((DAYS - 1)))
    today_short=$(days_ago_short 0)

    # 检查数据文件
    if [ ! -f "$DATA" ]; then
        echo "$(date): ERROR - reading-time.tsv not found"
        total_seconds=0
        reading_days=0
        book_count=0
        daily_seconds=""
        book_list=""
        return
    fi

    # 周期内总时长
    total_seconds=$(awk -F '\t' -v s="$start_date" 'NR>1&&$1>=s{sum+=$3}END{print sum+0}' "$DATA")

    # 阅读天数
    reading_days=$(awk -F '\t' -v s="$start_date" 'NR>1&&$1>=s&&$3>0{a[$1]=1}END{for(k in a)n++;print n+0}' "$DATA")

    # 书籍数量
    book_count=$(awk -F '\t' -v s="$start_date" 'NR>1&&$1>=s{a[$2]=1}END{for(k in a)n++;print n+0}' "$DATA")

    # 每日时长（7天，从旧到新）
    daily_seconds=""
    i=$((DAYS - 1))
    while [ $i -ge 0 ]; do
        d=$(days_ago_date $i)
        sec=$(awk -F '\t' -v d="$d" 'NR>1&&$1==d{s+=$3}END{print s+0}' "$DATA")
        daily_seconds="$daily_seconds $sec"
        i=$((i - 1))
    done

    # 书单 Top N（按时长降序）
    book_list=$(awk -F '\t' -v s="$start_date" 'NR>1&&$1>=s{k=$2 SUBSEP $4;s[k]+=$3}END{for(k in s){split(k,a,SUBSEP);print s[k]"\t"a[2]"\t"a[1]}}' "$DATA" | sort -nr | head -"$TOP_N")

    # 刷新书籍进度缓存
    refresh_progress_cache

    # 电池电量
    battery=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null || echo "?")
}

# ========== 伪二维码生成（PBM 格式） ==========

draw_pseudo_qr() {
    qr_x="$1"; qr_y="$2"; qr_size="$3"
    qr_file="/tmp/inkstain_qr.pbm"
    seed=$(date +%Y%m%d | tr -cd '0-9')
    [ -z "$seed" ] && seed=20260817
    # 确保 seed 在 Park-Miller 有效范围内
    seed=$((seed % 2147483647))
    [ "$seed" -le 0 ] && seed=12345

    awk -v seed="$seed" '
    BEGIN {
        print "P1"
        print "21 21"
        state = seed
        if (state <= 0) state = 12345
        for (row = 0; row < 21; row++) {
            line = ""
            for (col = 0; col < 21; col++) {
                val = 0
                # 定位角判定函数
                in_finder = 0
                # 左上角 (0-6, 0-6)
                if (row <= 6 && col <= 6) in_finder = 1
                # 右上角 (0-6, 14-20)
                if (row <= 6 && col >= 14) in_finder = 1
                # 左下角 (14-20, 0-6)
                if (row >= 14 && col <= 6) in_finder = 1
                # 分隔线 (row 7 或 col 7 在角落区域)
                if (row == 7 && col <= 7) in_finder = 1
                if (col == 7 && row <= 7) in_finder = 1
                if (row == 7 && col >= 13) in_finder = 1
                if (col == 13 && row <= 7) in_finder = 1
                if (row == 13 && col <= 7) in_finder = 1
                if (col == 7 && row >= 13) in_finder = 1

                if (in_finder) {
                    # 定位角内部图案
                    # 左上角
                    if (row <= 6 && col <= 6) {
                        if (row == 0 || row == 6 || col == 0 || col == 6) val = 1
                        else if (row >= 2 && row <= 4 && col >= 2 && col <= 4) val = 1
                    }
                    # 右上角
                    else if (row <= 6 && col >= 14) {
                        lr = row; lc = col - 14
                        if (lr == 0 || lr == 6 || lc == 0 || lc == 6) val = 1
                        else if (lr >= 2 && lr <= 4 && lc >= 2 && lc <= 4) val = 1
                    }
                    # 左下角
                    else if (row >= 14 && col <= 6) {
                        lr = row - 14; lc = col
                        if (lr == 0 || lr == 6 || lc == 0 || lc == 6) val = 1
                        else if (lr >= 2 && lr <= 4 && lc >= 2 && lc <= 4) val = 1
                    }
                    # 分隔线区域保持白色 (val = 0)
                }
                # 时序图案
                else if (row == 6 && col >= 8 && col <= 12) {
                    val = (col % 2 == 0) ? 1 : 0
                }
                else if (col == 6 && row >= 8 && row <= 12) {
                    val = (row % 2 == 0) ? 1 : 0
                }
                # 数据区：Park-Miller 伪随机
                else {
                    state = (state * 48271) % 2147483647
                    if (state < 0) state = state + 2147483647
                    val = (state % 2 == 0) ? 1 : 0
                }

                if (col > 0) line = line " "
                line = line val
            }
            print line
        }
    }' > "$qr_file"

    "$FBINK" -q -b -g "file=$qr_file,x=$qr_x,y=$qr_y,w=$qr_size,h=$qr_size"
    rm -f "$qr_file"
}

# ========== 伪条码生成（PBM 格式） ==========

draw_barcode() {
    bc_x="$1"; bc_y="$2"; bc_w="$3"; bc_h="$4"; bc_data="$5"
    bc_file="/tmp/inkstain_barcode.pbm"

    awk -v data="$bc_data" -v h="$bc_h" -v w="$bc_w" '
    BEGIN {
        print "P1"
        print w, h
        n = length(data)
        if (n == 0) { n = 1; data = "0" }
        for (row = 0; row < h; row++) {
            line = ""
            for (col = 0; col < w; col++) {
                # 根据数据字符的 ASCII 值生成条码模式
                idx = (col % (n * 4))
                char_idx = int(idx / 4) + 1
                if (char_idx > n) char_idx = n
                c = substr(data, char_idx, 1)
                # 字符 ASCII 近似值
                aval = index("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-.", toupper(c))
                if (aval == 0) aval = 1
                phase = idx % 4
                # 三种条宽模式
                m = aval % 3
                if (m == 0) val = (phase < 2) ? 1 : 0
                else if (m == 1) val = (phase < 1) ? 1 : 0
                else val = (phase < 3) ? 1 : 0
                if (col > 0) line = line " "
                line = line val
            }
            print line
        }
    }' > "$bc_file"

    "$FBINK" -q -b -g "file=$bc_file,x=$bc_x,y=$bc_y,w=$bc_w,h=$bc_h"
    rm -f "$bc_file"
}

# ========== 柱状图绘制 ==========

draw_chart() {
    chart_top="$1"
    # 图表高度：屏高 11.5% 与 scale 下限取大（对标 KOReader 第 3973 行）
    chart_h=$(( (H * 115) / 1000 ))
    [ "$chart_h" -lt $(( (60 * SCALE) )) ] && chart_h=$(( (60 * SCALE) ))
    [ "$chart_h" -lt 250 ] && chart_h=250
    chart_x=$((MARGIN_X + 10))
    chart_w=$((CONTENT_W - 20))
    chart_bottom=$((chart_top + chart_h))

    # Y 轴
    vline "$chart_top" "$chart_x" "$chart_h"
    # X 轴
    hline "$chart_bottom" "$chart_x" "$chart_w"

    # 解析每日数据
    set -- $daily_seconds
    day1="$1"; day2="$2"; day3="$3"; day4="$4"; day5="$5"; day6="$6"; day7="$7"

    # 找最大值
    max_s=1
    for s in "$day1" "$day2" "$day3" "$day4" "$day5" "$day6" "$day7"; do
        [ -n "$s" ] && [ "$s" -gt "$max_s" ] && max_s="$s"
    done

    # 最小可见高度阈值
    min_scale=300
    [ "$max_s" -lt "$min_scale" ] && max_s=$min_scale

    # 折线图：计算 7 个点坐标，连点成线（对标 KOReader 第 4049-4069 行）
    chart_inner_h=$((chart_h - 30))
    bar_count=7
    bar_gap=$((chart_w / bar_count))
    pts_x=""
    pts_y=""
    prev_x=""
    prev_y=""

    i=0
    for s in "$day1" "$day2" "$day3" "$day4" "$day5" "$day6" "$day7"; do
        [ -z "$s" ] && s=0
        # X 坐标：均匀分布
        px=$((chart_x + bar_gap / 2 + i * bar_gap))
        # Y 坐标：值越大越靠上
        if [ "$s" -gt 0 ]; then
            py=$((chart_bottom - s * chart_inner_h / max_s))
        else
            py=$chart_bottom
        fi

        # 连线（从第二个点开始）
        if [ -n "$prev_x" ]; then
            # 画线（简化版：用矩形模拟，粗细 3px）
            draw_line "$prev_x" "$prev_y" "$px" "$py"
        fi

        # 数据点：画小方块
        rect $((py - 4)) $((px - 4)) 8 8 BLACK

        # 在点上方显示分钟数（只标最大值）
        if [ "$s" -gt 0 ] && [ "$s" -ge "$max_s" ]; then
            mins=$((s / 60))
            [ "$mins" -gt 0 ] && ot_center "$tiny_px" $((py - tiny_px - 10)) $((px - 40)) $((px + 40)) BOLD "${mins}分"
        fi

        # 日期标签
        label=$(days_ago_short $((6 - i)))
        ot_center "$tiny_px" $((chart_bottom + 10)) $((px - bar_gap / 2)) $((px + bar_gap / 2)) REGULAR "$label"

        prev_x="$px"
        prev_y="$py"
        i=$((i + 1))
    done
}

# 画线函数（Bresenham 简化版，用矩形填充像素）
draw_line() {
    x1="$1"; y1="$2"; x2="$3"; y2="$4"
    if [ "$x1" -eq "$x2" ]; then
        # 垂直线
        top=$y1; bot=$y2
        [ "$y1" -gt "$y2" ] && { top=$y2; bot=$y1; }
        rect "$top" "$x1" 3 $((bot - top + 1)) BLACK
    elif [ "$y1" -eq "$y2" ]; then
        # 水平线
        left=$x1; right=$x2
        [ "$x1" -gt "$x2" ] && { left=$x2; right=$x1; }
        rect "$y1" "$left" $((right - left + 1)) 3 BLACK
    else
        # 对角线：分段画矩形，步长4px减少FBInk调用
        dx=$((x2 - x1)); dy=$((y2 - y1))
        [ "$dx" -lt 0 ] && dx=$(( -dx ))
        [ "$dy" -lt 0 ] && dy=$(( -dy ))
        steps=$dx
        [ "$dy" -gt "$steps" ] && steps=$dy
        [ "$steps" -lt 1 ] && steps=1
        step_size=4
        sx=1; sy=1
        [ "$x2" -lt "$x1" ] && sx=-1
        [ "$y2" -lt "$y1" ] && sy=-1
        j=0
        while [ "$j" -le "$steps" ]; do
            lx=$((x1 + sx * j * dx / steps))
            ly=$((y1 + sy * j * dy / steps))
            rect "$ly" "$lx" 5 5 BLACK
            j=$((j + step_size))
        done
    fi
}

# ========== 诗词与名言 ==========

# 内置诗词库 (诗句|朝代·作者|作品名)
get_random_poem() {
    poems="醉后不知天在水，满船清梦压星河。|元·唐珙|题龙阳县青草湖
人生若只如初见，何事秋风悲画扇。|清·纳兰性德|木兰花·拟古决绝词柬友
桃李春风一杯酒，江湖夜雨十年灯。|宋·黄庭坚|寄黄几复
读书破万卷，下笔如有神。|唐·杜甫|奉赠韦左丞丈二十二韵
问渠那得清如许，为有源头活水来。|宋·朱熹|观书有感
纸上得来终觉浅，绝知此事要躬行。|宋·陆游|冬夜读书示子聿
书山有路勤为径，学海无涯苦作舟。|唐·韩愈|古今贤文
粗缯大布裹生涯，腹有诗书气自华。|宋·苏轼|和董传留别
半亩方塘一鉴开，天光云影共徘徊。|宋·朱熹|观书有感
采得百花成蜜后，为谁辛苦为谁甜。|唐·罗隐|蜂"
    count=$(printf '%s\n' "$poems" | wc -l)
    idx=$(awk -v count="$count" -v seed="$$" 'BEGIN{srand(seed); print int(rand()*count)+1}')
    [ "$idx" -lt 1 ] && idx=1
    [ "$idx" -gt "$count" ] && idx=1
    printf '%s\n' "$poems" | sed -n "${idx}p"
}

# 内置名言库 (名言|人物|出处)
get_random_quote() {
    quotes="读万卷书，行万里路。|顾炎武|日知录
书籍是人类进步的阶梯。|高尔基|名言录
读书好，读好书，好读书。|冰心|繁星·春水
读书不是为了雄辩和驳斥，也不是为了轻信和盲从。|培根|论读书
读书是在别人思想的帮助下，建立起自己的思想。|鲁巴金|名言录
书到用时方恨少，事非经过不知难。|陆游|古今贤文
读过一本好书，像交了一个益友。|臧克家|名言录
阅读最大的理由是想摆脱平庸，早一天就多一份人生的精彩。|余秋雨|文化苦旅
读书足以怡情，足以傅彩，足以长才。|培根|论读书
一个人的精神发育史就是他的阅读史。|朱永新|我的阅读观"
    count=$(printf '%s\n' "$quotes" | wc -l)
    idx=$(awk -v count="$count" -v seed="$$" 'BEGIN{srand(seed+1); print int(rand()*count)+1}')
    [ "$idx" -lt 1 ] && idx=1
    [ "$idx" -gt "$count" ] && idx=1
    printf '%s\n' "$quotes" | sed -n "${idx}p"
}

# ========== 胶片票根风格辅助函数 ==========

# 获取最近阅读的书籍信息，输出: title \t book_id
get_current_book_info() {
    if [ ! -f "$DATA" ]; then
        printf '无阅读记录\t'
        return
    fi
    # 取最近日期的记录，输出 title 和 book_id
    awk -F '\t' 'NR>1{print $1"\t"$2"\t"$4}' "$DATA" 2>/dev/null | sort -r | head -1 | awk -F '\t' '{print $3"\t"$2}'
}

# 今日阅读秒数
get_today_seconds() {
    today=$(date +%Y-%m-%d)
    awk -F '\t' -v d="$today" 'NR>1&&$1==d{sum+=$3}END{print sum+0}' "$DATA" 2>/dev/null
}

# 指定书籍的总阅读秒数
get_book_total_seconds() {
    bid="$1"
    [ -z "$bid" ] && { echo 0; return; }
    awk -F '\t' -v b="$bid" 'NR>1&&$2==b{sum+=$3}END{print sum+0}' "$DATA" 2>/dev/null
}

# 中文星期
get_weekday_cn() {
    case $(date +%u) in
        1) echo "星期一" ;; 2) echo "星期二" ;; 3) echo "星期三" ;;
        4) echo "星期四" ;; 5) echo "星期五" ;; 6) echo "星期六" ;;
        7) echo "星期日" ;;
    esac
}

# 短格式周几（对标 KOReader getLocalizedDayName: 周一/周二/...）
get_weekday_short() {
    case $(date +%u) in
        1) echo "周一" ;; 2) echo "周二" ;; 3) echo "周三" ;;
        4) echo "周四" ;; 5) echo "周五" ;; 6) echo "周六" ;;
        7) echo "周日" ;;
    esac
}

# 虚线：draw_dotted_line <top> <left> <width>
draw_dotted_line() {
    dl_y="$1"; dl_x="$2"; dl_w="$3"
    dot_w=12; gap_w=12
    x=$dl_x
    while [ $x -lt $((dl_x + dl_w - dot_w)) ]; do
        rect "$dl_y" "$x" "$dot_w" 2 GRAY6
        x=$((x + dot_w + gap_w))
    done
}

# 胶片穿孔条：draw_film_strip <top> <left> <width> <height> <title>
draw_film_strip() {
    fs_y="$1"; fs_x="$2"; fs_w="$3"; fs_h="$4"; fs_title="$5"

    # 黑色背景
    rect "$fs_y" "$fs_x" "$fs_w" "$fs_h" BLACK

    # 穿孔（白色矩形近似圆孔）
    hole_w=28; hole_h=32; hole_gap=48
    hole_top_y=$((fs_y + 14))
    hole_bot_y=$((fs_y + fs_h - 14 - hole_h))

    x=$((fs_x + 25))
    while [ $x -lt $((fs_x + fs_w - hole_w - 25)) ]; do
        rect "$hole_top_y" "$x" "$hole_w" "$hole_h" WHITE
        rect "$hole_bot_y" "$x" "$hole_w" "$hole_h" WHITE
        x=$((x + hole_w + hole_gap))
    done

    # 书名不画在胶片条上（-F WHITE 可能不被此 FBInk 版本支持）
    # 书名已在下方进度盒子中显示
}

# ========== 胶片票根风格渲染 ==========

render_film() {
    echo "$(date): starting film receipt render"

    # 检查前置条件
    [ -x "$FBINK" ] || { echo "$(date): ERROR - FBInk not found"; return 1; }
    [ -f "$RFONT" ] || { echo "$(date): ERROR - Font not found"; return 1; }

    # 收集数据
    collect_stats

    # 获取当前书籍信息
    current_info=$(get_current_book_info)
    current_title=$(printf '%s' "$current_info" | cut -f1)
    current_bid=$(printf '%s' "$current_info" | cut -f2)
    current_progress=$(get_book_progress "$current_title")
    today_sec=$(get_today_seconds)
    book_total_sec=$(get_book_total_seconds "$current_bid")
    weekday=$(get_weekday_cn)
    weekday_short=$(get_weekday_short)
    battery=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null || echo "?")
    current_time=$(date +%H:%M)

    [ -z "$current_title" ] && current_title="暂无阅读记录"
    [ -z "$current_progress" ] && current_progress=0

    # 卡片尺寸（68% 居中）
    card_w=$((W * 68 / 100))
    card_x=$(( (W - card_w) / 2 ))
    card_h=1280
    card_y=$(( (H - card_h) / 2 ))

    inner_x=$((card_x + 4))
    inner_w=$((card_w - 8))
    pad_x=$((card_x + 45))
    pad_w=$((card_w - 90))

    # 0. 单次清屏（-f 刷新，后续所有绘制用 -b 不刷新，最后统一 -f）
    "$FBINK" -q -k -W GC16 -f

    # 1. 阴影（灰色矩形，偏移 +12）
    rect $((card_y + 12)) $((card_x + 12)) "$card_w" "$card_h" GRAYB

    # 2. 卡片背景（白色）
    rect "$card_y" "$card_x" "$card_w" "$card_h" WHITE

    # 3. 卡片边框
    hline "$card_y" "$card_x" "$card_w"
    hline $((card_y + card_h - 2)) "$card_x" "$card_w"
    vline "$card_y" "$card_x" "$card_h"
    vline "$card_y" $((card_x + card_w - 2)) "$card_h"

    # ========== 4. 顶部区：封面占位 + 装饰列 + 日历 ==========
    sec1_y=$((card_y + 40))

    # 封面占位（左侧）
    cover_x=$pad_x
    cover_w=300
    cover_h=400
    rect "$sec1_y" "$cover_x" "$cover_w" "$cover_h" GRAY6
    hline "$sec1_y" "$cover_x" "$cover_w"
    hline $((sec1_y + cover_h - 2)) "$cover_x" "$cover_w"
    vline "$sec1_y" "$cover_x" "$cover_h"
    vline "$sec1_y" $((cover_x + cover_w - 2)) "$cover_h"
    ot_center 28 $((sec1_y + 160)) "$cover_x" $((cover_x + cover_w)) REGULAR "书籍"
    ot_center 22 $((sec1_y + 210)) "$cover_x" $((cover_x + cover_w)) REGULAR "封面"

    # 装饰列（"|" 竖排）
    deco_x=$((cover_x + cover_w + 40))
    i=0
    while [ $i -lt 8 ]; do
        ot 20 $((sec1_y + i * 45)) "$deco_x" $((deco_x + 30)) REGULAR "|"
        i=$((i + 1))
    done

    # 日历（右侧）
    cal_x=$((deco_x + 60))
    cal_right=$((card_x + card_w - 45))
    ot 40 "$sec1_y" "$cal_x" "$cal_right" BOLD "$(date +%Y.%m)"
    ot 100 $((sec1_y + 50)) "$cal_x" "$cal_right" BOLD "$(date +%d)"
    ot 28 $((sec1_y + 180)) "$cal_x" "$cal_right" REGULAR "$weekday"
    ot 24 $((sec1_y + 220)) "$cal_x" "$cal_right" REGULAR "休眠中"

    # ========== 5. 虚线分隔 ==========
    dot_y=$((sec1_y + cover_h + 30))
    draw_dotted_line "$dot_y" "$inner_x" "$inner_w"

    # ========== 6. 胶片穿孔条 ==========
    strip_y=$((dot_y + 25))
    strip_h=140
    draw_film_strip "$strip_y" "$inner_x" "$inner_w" "$strip_h" "$current_title"

    # ========== 7. 进度盒子 1：当前书籍（对标 KOReader bookbox databox）==========
    box1_y=$((strip_y + strip_h + 40))

    ot 26 "$box1_y" "$pad_x" $((pad_x + pad_w)) BOLD "当前书籍"
    ot 30 $((box1_y + 35)) "$pad_x" $((pad_x + pad_w)) BOLD "$current_title"

    # 进度条（对标 KOReader ProgressWidget: bgcolor=lightest, fillcolor=black）
    bar1_y=$((box1_y + 80))
    bar1_h=24
    rect "$bar1_y" "$pad_x" "$pad_w" "$bar1_h" GRAYB
    bar1_fill=$(( (pad_w * current_progress) / 100 ))
    [ "$bar1_fill" -gt 0 ] && rect "$bar1_y" "$pad_x" "$bar1_fill" "$bar1_h" BLACK

    # 页码进度 + 百分比（对标 KOReader page_progress + percentage_display）
    ot 22 $((bar1_y + bar1_h + 10)) "$pad_x" $((pad_x + pad_w / 2)) REGULAR "阅读进度"
    ot 22 $((bar1_y + bar1_h + 10)) $((pad_x + (pad_w * 3) / 4)) $((pad_x + pad_w)) REGULAR "${current_progress}%"

    # ========== 8. 进度盒子 2：阅读统计（对标 KOReader chapterbox + stats）==========
    box2_y=$((bar1_y + bar1_h + 50))

    ot 26 "$box2_y" "$pad_x" $((pad_x + pad_w)) BOLD "阅读统计"

    # 今天阅读 (周X) — 对标 KOReader book_today_time_text
    today_text=$(format_time_cn "$today_sec")
    ot 22 $((box2_y + 35)) "$pad_x" $((pad_x + pad_w)) REGULAR "今天阅读 (${weekday_short})：${today_text}"

    # 全书已阅读 — 对标 KOReader book_total_time_text
    book_total_text=$(format_time_cn "$book_total_sec")
    ot 22 $((box2_y + 65)) "$pad_x" $((pad_x + pad_w)) REGULAR "全书已阅读：${book_total_text}"

    # 近7天合计
    period_total_text=$(format_time_cn "$total_seconds")
    ot 22 $((box2_y + 95)) "$pad_x" $((pad_x + pad_w)) REGULAR "近${DAYS}天合计：${period_total_text}（${reading_days}天）"

    # 活跃度进度条
    bar2_y=$((box2_y + 125))
    bar2_h=24
    active_ratio=0
    [ "$DAYS" -gt 0 ] && active_ratio=$(( (reading_days * 100) / DAYS ))
    rect "$bar2_y" "$pad_x" "$pad_w" "$bar2_h" GRAYB
    bar2_fill=$(( (pad_w * active_ratio) / 100 ))
    [ "$bar2_fill" -gt 0 ] && rect "$bar2_y" "$pad_x" "$bar2_fill" "$bar2_h" BLACK
    ot 22 $((bar2_y + bar2_h + 10)) "$pad_x" $((pad_x + pad_w / 2)) REGULAR "活跃度"
    ot 22 $((bar2_y + bar2_h + 10)) $((pad_x + (pad_w * 3) / 4)) $((pad_x + pad_w)) REGULAR "${reading_days}/${DAYS}天"

    # ========== 9. 花朵按钮分隔（对标 KOReader separator_row with badge）==========
    sep_y=$((bar2_y + bar2_h + 45))

    flower_w=60
    left_sep_w=$(( (pad_w - flower_w) / 2 ))
    draw_dotted_line "$sep_y" "$pad_x" "$left_sep_w"

    # 花朵标记：用绘制的小菱形代替花朵字符（避免字体缺字导致 FBInk 崩溃）
    flower_cx=$((pad_x + left_sep_w + flower_w / 2))
    flower_cy=$((sep_y + 1))
    rect $((flower_cy - 6)) $((flower_cx - 2)) 4 12 BLACK
    rect $((flower_cy - 2)) $((flower_cx - 6)) 12 4 BLACK
    rect $((flower_cy - 4)) $((flower_cx - 4)) 8 8 BLACK

    right_sep_x=$((pad_x + left_sep_w + flower_w))
    right_sep_w=$((pad_w - left_sep_w - flower_w))
    draw_dotted_line "$sep_y" "$right_sep_x" "$right_sep_w"

    # ========== 10. 底部栏：电量 + 时钟 ==========
    bot_y=$((sep_y + 40))
    ot 22 "$bot_y" "$pad_x" $((pad_x + 200)) REGULAR "电量：${battery}%"
    ot_center 22 "$bot_y" $((card_x + card_w - 250)) $((card_x + card_w - 45)) REGULAR "$current_time"

    # ========== 11. 竞态防护：渲染前状态检查 ==========
    if [ "$SKIP_STATE_CHECK" != "1" ]; then
        if ! check_power_state; then
            echo "$(date): device woke up before refresh, aborting film render"
            return 1
        fi
    fi

    # 记录验证点（胶片穿孔条黑色区域中心）
    VERIFY_X=$((inner_x + 50))
    VERIFY_Y=$((strip_y + strip_h / 2))

    # ========== 12. 最终全屏刷新 ==========
    "$FBINK" -q -s -f -W GC16

    echo "$(date): film receipt render completed"
}

# ========== 主渲染函数 ==========

render_inkstain() {
    echo "$(date): starting inkstain render"

    # 检查前置条件
    [ -x "$FBINK" ] || { echo "$(date): ERROR - FBInk not found"; return 1; }
    [ -f "$RFONT" ] || { echo "$(date): ERROR - Font not found"; return 1; }

    # 收集数据
    collect_stats

    # 0. 单次清屏（-f 刷新，后续所有绘制用 -b 不刷新，最后统一 -f）
    "$FBINK" -q -k -W GC16 -f

    # ========== 1. 标题区 ==========
    # 「墨」「痕」横排大字（右上角）— KOReader 点→像素换算：pt * 300 / 72
    # title: min(48, 42*scale) pt → 48pt = 200px @ 300dpi
    title_pt=$(( (42 * SCALE) ))
    [ "$title_pt" -gt 48 ] && title_pt=48
    [ "$title_pt" -lt 32 ] && title_pt=32
    title_px=$(( (title_pt * 300) / 72 ))
    en_pt=$(( (title_pt * 32) / 100 ))
    en_px=$(( (en_pt * 300) / 72 ))
    ot "$title_px" "$MARGIN_Y" $((W - MARGIN_X - 340)) $((W - MARGIN_X - 170)) BOLD "墨"
    ot "$title_px" "$MARGIN_Y" $((W - MARGIN_X - 170)) $((W - MARGIN_X)) BOLD "痕"
    ot "$en_px" $((MARGIN_Y + title_px + 8)) $((W - MARGIN_X - 340)) $((W - MARGIN_X)) REGULAR "ink stain"

    # 单号（左上角）— KOReader large: min(30, 26*scale) pt → 30pt = 125px
    large_pt=$(( (26 * SCALE) ))
    [ "$large_pt" -gt 30 ] && large_pt=30
    [ "$large_pt" -lt 20 ] && large_pt=20
    large_px=$(( (large_pt * 300) / 72 ))
    ot "$large_px" "$MARGIN_Y" "$MARGIN_X" $((W / 2)) BOLD "单号：$(date +%m%d)"

    # ========== 2. 信息区 ==========
    # KOReader small: min(12, 10*scale) pt → 12pt = 50px
    small_pt=$(( (10 * SCALE) ))
    [ "$small_pt" -gt 12 ] && small_pt=12
    [ "$small_pt" -lt 9 ] && small_pt=9
    small_px=$(( (small_pt * 300) / 72 ))
    # KOReader normal: min(15, 13*scale) pt → 15pt = 63px
    normal_pt=$(( (13 * SCALE) ))
    [ "$normal_pt" -gt 15 ] && normal_pt=15
    [ "$normal_pt" -lt 11 ] && normal_pt=11
    normal_px=$(( (normal_pt * 300) / 72 ))
    # KOReader tiny: min(10, 8*scale) pt → 10pt = 42px
    tiny_pt=$(( (8 * SCALE) ))
    [ "$tiny_pt" -gt 10 ] && tiny_pt=10
    [ "$tiny_pt" -lt 8 ] && tiny_pt=8
    tiny_px=$(( (tiny_pt * 300) / 72 ))

    info_y=$((MARGIN_Y + large_px + 20))
    ot "$small_px" "$info_y" "$MARGIN_X" $((W - MARGIN_X)) REGULAR "时间：${start_short} - ${today_short}"

    info_y=$((info_y + small_px + 18))
    # 设备信息
    batt_text=""
    [ -n "$battery" ] && [ "$battery" != "?" ] && batt_text="  电量：${battery}%"
    ot "$small_px" "$info_y" "$MARGIN_X" $((W - MARGIN_X)) REGULAR "设备：Kindle Scribe  10.2寸  1860×2480  300dpi${batt_text}"

    # ========== 3. 时长 + 书单标题 ==========
    info_y=$((info_y + small_px + 25))
    duration_text=$(format_days "$total_seconds")
    ot "$normal_px" "$info_y" "$MARGIN_X" $((W / 2)) BOLD "时长：${duration_text}"
    ot_center "$normal_px" "$info_y" $((W - MARGIN_X - 450)) $((W - MARGIN_X)) BOLD "书单：Top ${TOP_N}"

    # ========== 4. 分隔线 ==========
    sep_y=$((info_y + normal_px + 25))
    hline "$sep_y" "$MARGIN_X" "$CONTENT_W"

    # ========== 5. 表头 ==========
    header_y=$((sep_y + 20))
    ot "$small_px" "$header_y" "$MARGIN_X" $((MARGIN_X + 280)) REGULAR "品类"
    ot_center "$small_px" "$header_y" $((W - MARGIN_X - 280)) $((W - MARGIN_X - 160)) REGULAR "数量"
    ot_center "$small_px" "$header_y" $((W - MARGIN_X - 140)) $((W - MARGIN_X)) REGULAR "单位"

    # ========== 6. 分隔线 ==========
    sep_y=$((header_y + small_px + 18))
    hline "$sep_y" "$MARGIN_X" "$CONTENT_W"

    # ========== 7. 书单表格 ==========
    rows_top=$((sep_y + 20))
    # 行高对标 KOReader: 52*scale，但我们的内容行多(书名+时长+进度+进度条)
    row_h=$(( (55 * SCALE) ))
    [ "$row_h" -lt 150 ] && row_h=150
    [ "$row_h" -gt 220 ] && row_h=220
    x_no="$MARGIN_X"
    x_title=$((MARGIN_X + 160))
    x_qty=$((W - MARGIN_X - 280))
    x_unit=$((W - MARGIN_X - 100))
    title_w=$((x_qty - x_title - 40))

    row_idx=0
    if [ -n "$book_list" ]; then
        printf '%s\n' "$book_list" | while IFS="$(printf '\t')" read -r sec title id; do
            [ -z "$title" ] && continue
            row_idx=$((row_idx + 1))
            [ "$row_idx" -gt "$TOP_N" ] && break

            row_y=$((rows_top + (row_idx - 1) * row_h))

            # 编号 + 书名（normal_px）
            ot "$normal_px" "$row_y" "$x_no" $((x_no + 140)) BOLD "No.0${row_idx}"
            ot "$normal_px" "$row_y" "$x_title" $((x_title + title_w)) BOLD "$title"

            # 详情行（tiny_px）
            duration_text=$(format_time "$sec")
            ot "$tiny_px" $((row_y + normal_px + 10)) "$x_title" $((x_title + title_w)) REGULAR "本期：${duration_text}"

            # 进度行
            progress=$(get_book_progress "$title")
            if [ -n "$progress" ]; then
                ot "$tiny_px" $((row_y + normal_px + tiny_px + 18)) "$x_title" $((x_title + title_w)) REGULAR "进度：${progress}%"
                # 进度条
                bar_y=$((row_y + normal_px + tiny_px * 2 + 28))
                bar_full_w=$((title_w))
                bar_fill_w=$((bar_full_w * progress / 100))
                rect "$bar_y" "$x_title" "$bar_full_w" 10 GRAY6
                [ "$bar_fill_w" -gt 0 ] && rect "$bar_y" "$x_title" "$bar_fill_w" 10 BLACK
            else
                ot "$tiny_px" $((row_y + normal_px + tiny_px + 18)) "$x_title" $((x_title + title_w)) REGULAR "进度：暂无"
            fi

            # 数量列 + 单位列
            ot_center "$normal_px" "$row_y" "$x_qty" $((x_qty + 100)) BOLD "1"
            ot_center "$normal_px" "$row_y" "$x_unit" $((W - MARGIN_X)) BOLD "本"
        done
    else
        ot "$normal_px" $((rows_top + 20)) "$MARGIN_X" $((W - MARGIN_X)) REGULAR "本周期暂无阅读记录"
    fi

    # 补充空行（保持表格高度稳定）
    current_rows=0
    if [ -n "$book_list" ]; then
        current_rows=$(printf '%s\n' "$book_list" | grep -c . 2>/dev/null || echo 0)
        [ "$current_rows" -gt "$TOP_N" ] && current_rows=$TOP_N
    fi
    empty_idx=$current_rows
    while [ "$empty_idx" -lt "$TOP_N" ]; do
        empty_idx=$((empty_idx + 1))
        row_y=$((rows_top + (empty_idx - 1) * row_h))
        ot "$tiny_px" "$row_y" "$x_no" $((x_no + 140)) REGULAR "No.0${empty_idx}"
        if [ "$current_rows" -eq 0 ] && [ "$empty_idx" -eq 1 ]; then
            ot "$small_px" "$row_y" "$x_title" $((x_title + title_w)) REGULAR "等待阅读数据…"
            ot "$tiny_px" $((row_y + small_px + 10)) "$x_title" $((x_title + title_w)) REGULAR "请用原生阅读器打开书籍"
        else
            ot "$tiny_px" "$row_y" "$x_title" $((x_title + title_w)) REGULAR "—"
        fi
    done

    # ========== 8. 分隔线 ==========
    table_bottom=$((rows_top + TOP_N * row_h + 10))
    hline "$table_bottom" "$MARGIN_X" "$CONTENT_W"

    # ========== 9. 汇总行 ==========
    summary_y=$((table_bottom + 25))
    avg_seconds=0
    [ "$reading_days" -gt 0 ] && avg_seconds=$((total_seconds / reading_days))
    avg_text=$(format_time "$avg_seconds")
    total_text=$(format_time "$total_seconds")
    ot "$normal_px" "$summary_y" "$MARGIN_X" $((W / 2)) BOLD "日均：${avg_text}"
    ot_center "$normal_px" "$summary_y" $((W - MARGIN_X - 500)) $((W - MARGIN_X)) BOLD "合计：${total_text}"

    # ========== 10. 折线图 ==========
    chart_top=$((summary_y + normal_px + 30))
    draw_chart "$chart_top"

    # ========== 11. 二维码 + 条码带 ==========
    qr_size=$(( (42 * SCALE) ))
    [ "$qr_size" -lt 120 ] && qr_size=120
    [ "$qr_size" -gt 200 ] && qr_size=200
    chart_h=$(( (60 * SCALE) ))
    [ "$chart_h" -lt 250 ] && chart_h=250
    chart_bottom=$((chart_top + chart_h))
    footer_y=$((chart_bottom + 50))

    draw_pseudo_qr "$MARGIN_X" "$footer_y" "$qr_size"

    # 条码
    bc_x=$((MARGIN_X + qr_size + 30))
    bc_y=$((footer_y + 20))
    bc_w=$((W - MARGIN_X - bc_x))
    bc_h=$(( (34 * SCALE) ))
    [ "$bc_h" -lt 60 ] && bc_h=60
    barcode_data="${today_date//-/}-$(printf '%s' "$total_seconds" | tail -c 5)-${book_count}"
    draw_barcode "$bc_x" "$bc_y" "$bc_w" "$bc_h" "$barcode_data"

    # ========== 12. 诗词 + 名言 ==========
    poem_top=$((footer_y + qr_size + 40))
    poem_line=$(get_random_poem)
    quote_line=$(get_random_quote)

    # 解析诗词
    poem_text=$(printf '%s' "$poem_line" | cut -d'|' -f1)
    poem_author=$(printf '%s' "$poem_line" | cut -d'|' -f2)
    poem_work=$(printf '%s' "$poem_line" | cut -d'|' -f3)

    # 解析名言
    quote_text=$(printf '%s' "$quote_line" | cut -d'|' -f1)
    quote_person=$(printf '%s' "$quote_line" | cut -d'|' -f2)
    quote_source=$(printf '%s' "$quote_line" | cut -d'|' -f3)

    # 诗词（左，3行）— small_px + tiny_px
    ot "$small_px" "$poem_top" "$MARGIN_X" $((W / 2 - 40)) REGULAR "$poem_text"
    ot "$tiny_px" $((poem_top + small_px + 12)) "$MARGIN_X" $((W / 2 - 40)) REGULAR "$poem_author"
    ot "$tiny_px" $((poem_top + small_px + tiny_px + 24)) "$MARGIN_X" $((W / 2 - 40)) REGULAR "《${poem_work}》"

    # 名言（右，3行）
    ot_center "$small_px" "$poem_top" $((W / 2 + 40)) $((W - MARGIN_X)) REGULAR "「${quote_text}」"
    ot_center "$tiny_px" $((poem_top + small_px + 12)) $((W / 2 + 40)) $((W - MARGIN_X)) REGULAR "$quote_person"
    ot_center "$tiny_px" $((poem_top + small_px + tiny_px + 24)) $((W / 2 + 40)) $((W - MARGIN_X)) REGULAR "《${quote_source}》"

    # ========== 13. 竞态防护：渲染前状态检查 ==========
    if [ "$SKIP_STATE_CHECK" != "1" ]; then
        if ! check_power_state; then
            echo "$(date): device woke up before refresh, aborting inkstain render"
            return 1
        fi
    fi

    # 记录验证点（第一根分隔线上，黑色像素）
    VERIFY_X=$((MARGIN_X + 10))
    VERIFY_Y=$((MARGIN_Y + large_px + small_px * 2 + normal_px + 50))

    # ========== 14. 最终全屏刷新（唯一的显示刷新） ==========
    "$FBINK" -q -s -f -W GC16

    echo "$(date): inkstain render completed"
}

# ========== 执行 ==========

chosen_style=$(resolve_style)
echo "$(date): resolved style = $chosen_style"

# 首次渲染
case "$chosen_style" in
    film) render_film ;;
    *) render_inkstain ;;
esac
render_exit=$?

# 渲染被中止（设备已唤醒）：清屏让框架恢复界面
if [ $render_exit -ne 0 ]; then
    echo "$(date): render aborted, clearing screen for framework"
    "$FBINK" -q -k -W GC16 -f 2>/dev/null
    exit 0
fi

# 竞态防护：渲染后检查设备是否已唤醒
if [ "$SKIP_STATE_CHECK" != "1" ]; then
    if ! check_power_state; then
        echo "$(date): device woke up after render, clearing screen"
        "$FBINK" -q -k -W GC16 -f 2>/dev/null
        exit 0
    fi
fi

echo "$(date): render completed and stable"
exit 0
